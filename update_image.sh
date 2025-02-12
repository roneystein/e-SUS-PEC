#!/bin/bash

# Obter a versão mais recente
PAGE_URL="https://sisaps.saude.gov.br/esus/"

# Argumento para escolha do arquivo Docker Compose
DOCKER_COMPOSE_FILE=$1
if [ -z "$DOCKER_COMPOSE_FILE" ]; then
    echo "Erro: É necessário informar o arquivo de configuração Docker Compose como argumento."
    echo "Opções disponíveis: docker-compose.local-db.yml, docker-compose.external-db.yml"
    exit 1
fi

# Busca o link do novo arquivo
# ex. href="https://arquivos.esusab.ufsc.br/PEC/d21144cc4f66edef/5.3.25/eSUS-AB-PEC-5.3.25-Linux64.jar"
echo 'Buscando o link de download...'
HTML_CONTENT=$(curl -s "$PAGE_URL")
DOWNLOAD_URL=$(echo "$HTML_CONTENT" | grep -o 'href=\"[^\"]*Linux[^\"]*\"' | sed 's/href=\"//' | sed 's/\"//' | head -1)
echo "$DOWNLOAD_URL"

# Nova versao
VERSION_REGEX=".*-([0-9]+\.[0-9]+\.[0-9]+)-.*"
if [[ $DOWNLOAD_URL =~ $VERSION_REGEX ]]
  then
  NEW_VERSION="${BASH_REMATCH[1]}"
  echo "Versao encontrada: $NEW_VERSION"
else
  echo "Não foi possível identificar versão nova para download"
  exit 1
fi

# Verifica se o container está rodando
if ! docker compose -f "$DOCKER_COMPOSE_FILE" ps | grep -q "pec"; then
    echo "Erro: O serviço 'pec' não está rodando no arquivo de configuração $DOCKER_COMPOSE_FILE."
    exit 1
fi

# Verificar a versao em execucao
RUNNING_VERSION=$(docker compose -f "$DOCKER_COMPOSE_FILE" exec pec bash -c "cat /etc/pec.config | jq .version -r" )
echo "Versao em execucao: $RUNNING_VERSION"

if [[ $NEW_VERSION != "$RUNNING_VERSION" ]]
  then
    echo "Parando PEC para atualização."
    docker compose -f "$DOCKER_COMPOSE_FILE" down
    ./build -f "$DOWNLOAD_URL"
fi
