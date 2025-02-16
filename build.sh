#!/bin/bash

# Definição de cores
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Variáveis iniciais
cache=''
filename=''
https_domain=''
use_external_db=false
production=false

# Exibe ajuda do script
if [ "$1" = "--help" ]; then
    echo "
    Script para instalação do PEC

    Uso: build.sh [-f <nome do arquivo ou URL>] [-h <domínio HTTPS>] [-c] [-p] [-e]

    -f {nome do arquivo ou URL} para especificar o arquivo JAR a ser utilizado (busca o último se não informado)
    -c para não utilizar cache ao construir as imagens Docker
    -h {domínio HTTPS} para gerar o certificado
    -p para instalar em ambiente de produção
    -e para utilizar banco de dados externo especificado em .env
    "
    exit 0
fi

# Processa os argumentos
while getopts "d:f:h:cpe" flag; do
    case "${flag}" in
        f) filename=${OPTARG} ;;
        h) https_domain=${OPTARG} ;;
        c) cache='--no-cache' ;;
        p) production=true ;;
        e) use_external_db=true ;;
        \?)
            echo "${RED}Opção inválida! Utilize --help para ajuda.${NC}"
            exit 1
            ;;
    esac
done

# Caso production seja false determina training para true
if [ "$production" = false ]; then
    training=true
fi

# Caso o banco de dados for externo modifica a variável logo para produção
if [ "$use_external_db" = true ]; then
    production=true
fi

# Define timeout para o Docker Compose
export COMPOSE_HTTP_TIMEOUT=8000

# Carrega variáveis de ambiente do .env
echo "Carregando variáveis de .env..."
if [ -f ".env" ]; then
    set -a
    . .env
    set +a
    filename=${filename:-$FILENAME}
    https_domain=${https_domain:-$HTTPS_DOMAIN}
    echo -e "${GREEN}Arquivo .env carregado com sucesso.${NC}"
else
    echo -e "${RED}Arquivo .env não encontrado.${NC}"
    exit 1
fi

# Busca o link do arquivo JAR, caso não especificado
if [ -z "$filename" ]; then
    echo -e "${GREEN}Buscando link de instalação na página do PEC...${NC}"
    PAGE_URL="https://sisaps.saude.gov.br/esus/"
    HTML_CONTENT=$(curl -s "$PAGE_URL")
    DOWNLOAD_URL=$(echo "$HTML_CONTENT" | grep -o 'href="[^"]*Linux[^"]*' | sed 's/href="//' | head -1)

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}Erro: Link para download não encontrado.${NC}"
        exit 1
    fi

    case "$DOWNLOAD_URL" in
        http*) ;;
        *) 
            BASE_URL=$(echo "$PAGE_URL" | sed -n 's#\(https\?://[^/]*\).*#\1#p')
            DOWNLOAD_URL="$BASE_URL$DOWNLOAD_URL"
            ;;
    esac

    echo -e "${GREEN}Link para download encontrado: $DOWNLOAD_URL${NC}"
    filename="$DOWNLOAD_URL"
fi

# Faz o download do arquivo JAR
if echo "$filename" | grep -q '^https://'; then
    jar_filename=$(basename "$filename")
    save_path="./$jar_filename"
    if [ -f "$save_path" ]; then
        echo "O arquivo $jar_filename já existe. Não será baixado novamente."
    else
        echo "Baixando o arquivo $jar_filename..."
        wget -O "$save_path" "$filename"
        echo -e "${GREEN}Download concluído.${NC}"
    fi
else
    jar_filename="$filename"
fi

# Exibe mensagem de instalação
echo -e "${GREEN}Instalando e-SUS-PEC com o arquivo $jar_filename...${NC}"
docker compose -f docker-compose.local-db.yml down --volumes --remove-orphans
docker compose -f docker-compose.external-db.yml down --volumes --remove-orphans

# Verifica se o psql está disponível
if command -v psql > /dev/null; then
    echo "psql está instalado."
    if $use_external_db; then
        echo "Testando conexão com o banco de dados externo em $POSTGRES_HOST..."
        POSTGRES_HOST_FOR_TEST=$([ "$POSTGRES_HOST" = "host.docker.internal" ] && echo "localhost" || echo "$POSTGRES_HOST")
        if PGPASSWORD=$POSTGRES_PASS psql -h $POSTGRES_HOST_FOR_TEST -U $POSTGRES_USER -p $POSTGRES_PORT -d $POSTGRES_DB -c '\q'; then
            echo -e "${GREEN}Conexão ao banco de dados externa bem-sucedida.${NC}"
        else
            echo -e "${RED}Falha ao conectar ao banco de dados externo. Verifique as credenciais.${NC}"
            exit 1
        fi
    else
        echo "Sem banco de dados externo fornecido."
    fi
else
    echo -e "${RED}psql não está instalado. Conexão ao banco de dados não pode ser testada.${NC}"
fi


BUILD_VERSION="latest"

VERSION_REGEX=".*-([0-9]+\.[0-9]+\.[0-9]+)-.*"
if [[ $jar_filename =~ $VERSION_REGEX ]] ; then
  BUILD_VERSION="${BASH_REMATCH[1]}"
fi
export BUILD_VERSION

# Executa instalação com o Docker Compose correto
if $use_external_db; then
    jdbc_url="jdbc:postgresql://$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB?ssl=true&sslmode=allow&sslfactory=org.postgresql.ssl.NonValidatingFactory"
    echo -e "\n${GREEN}Construindo e subindo Docker com banco de dados externo...${NC}"
    docker compose --progress plain -f docker-compose.external-db.yml build $cache \
        --build-arg JAR_FILENAME=$jar_filename \
        --build-arg HTTPS_DOMAIN=$https_domain \
        --build-arg DB_URL=$jdbc_url

    # Se estiver gerenciado pelo Systemd
    if systemctl list-unit-files esuspec.service &>/dev/null ; then
        echo -e "Iniciando via Systemd..."
        sudo systemctl start esuspec.service
    else
        docker compose -f docker-compose.external-db.yml up -d
    fi
    
else
    jdbc_url="jdbc:postgresql://$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
    echo -e "\n${GREEN}Construindo e subindo Docker com banco de dados local...${NC}"
    echo "docker compose --progress plain -f docker-compose.local-db.yml build $cache \
        --build-arg JAR_FILENAME=$jar_filename \
        --build-arg HTTPS_DOMAIN=$https_domain \
        --build-arg DB_URL=$jdbc_url \
        --build-arg TRAINING=$training"
    docker compose --progress plain -f docker-compose.local-db.yml build $cache \
        --build-arg JAR_FILENAME=$jar_filename \
        --build-arg DB_URL=$jdbc_url \
        --build-arg TRAINING=$training

    # Se estiver gerenciado pelo Systemd
    if systemctl list-unit-files esuspec.service &>/dev/null ; then
        echo -e "Iniciando via Systemd..."
        sudo systemctl start esuspec.service
    else
        docker compose -f docker-compose.local-db.yml up -d
    fi

fi