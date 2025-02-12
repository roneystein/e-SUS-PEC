#!/bin/bash

DOWNLOAD_URL=$1
VERSION_REGEX=".*-([0-9]+\.[0-9]+\.[0-9]+)-.*"
if [[ $DOWNLOAD_URL =~ $VERSION_REGEX ]]
  then
  NEW_VERSION="${BASH_REMATCH[1]}"
  echo "$NEW_VERSION"
else
  echo "Não foi possível identificar versão nova para download" 1>&2
  exit 1
fi
