#!/bin/bash -e

if [ $# -eq 0 ]; then
    echo "No arguments provided"
    exit 1
fi


get_container_engine () {

    # allow override from callers such as oci-env
    if [ -z ${COMPOSE_BINARY} ]; then
        echo "${COMPOSE_BINARY}"
        return
    fi

    # use podman if found
    if command -v podman > /dev/null; then
        echo "podman"
        return
    fi

    # default to docker
    echo "docker"
}


container_engine=$(get_container_engine)
if [[ "${container_engine}" == "podman" ]]
then
  container_exec=podman
  ULIMIT_COMMAND=
  if [[ -n $PULP_MCS_LABEL ]]
  then
    USER_COMMAND="--userns=keep-id --security-opt label=level:$PULP_MCS_LABEL"
  else
    USER_COMMAND="--userns=keep-id"
  fi
else
  container_exec=docker
  if [[ -n $PULP_MCS_LABEL ]]
  then
    USER_COMMAND="-u $(id -u) --security-opt label=level:$PULP_MCS_LABEL"
  else
    USER_COMMAND="-u $(id -u)"
  fi
  ULIMIT_COMMAND="--ulimit nofile=122880:122880"
fi

if command -v getenforce > /dev/null
then
  if [ "$(getenforce)" == "Enforcing" ]
  then
    volume_name="/local:Z"
  else
    volume_name="/local"
  fi
else
  volume_name="/local"
fi

PULP_URL="${PULP_URL:-http://localhost:24817}"

PULP_API_ROOT="${PULP_API_ROOT:-/pulp/}"

PULP_URL="${PULP_URL}${PULP_API_ROOT}api/v3/"

# Download the schema
curl -k -o api.json "${PULP_URL}docs/api.json?bindings&plugin=$1"
# Get the version of the pulpcore or plugin as reported by status API

if [ $# -gt 2 ];
then
    export VERSION=$3
else
    # match the component name by removing the "pulp/pulp_" prefix
    if [ $1 = 'pulpcore' ]
    then
        COMPONENT_NAME="core"
    else
        COMPONENT_NAME=${1#"pulp_"}
    fi

    export VERSION=$(http ${PULP_URL}status/ | jq --arg plugin $COMPONENT_NAME -r '.versions[] | select(.component == $plugin) | .version')
fi

echo ::group::BINDINGS
if [ $2 = 'python' ]
then
    $container_exec run \
        $ULIMIT_COMMAND \
        $USER_COMMAND \
        --rm \
        -v ${PWD}:$volume_name \
        docker.io/openapitools/openapi-generator-cli:v4.3.1 generate \
        -i /local/api.json \
        -g python \
        -o /local/$1-client \
        --additional-properties=packageName=pulpcore.client.$1,projectName=$1-client,packageVersion=${VERSION} \
        -t /local/templates/python \
        --skip-validate-spec \
        --strict-spec=false
    cp python/__init__.py $1-client/pulpcore/
    cp python/__init__.py $1-client/pulpcore/client
fi
if [ $2 = 'ruby' ]
then
    # https://github.com/OpenAPITools/openapi-generator/wiki/FAQ#how-to-skip-certain-files-during-code-generation
    mkdir -p $1-client
    echo git_push.sh > $1-client/.openapi-generator-ignore

    python3 remove-cookie-auth.py
    $container_exec run \
        $ULIMIT_COMMAND \
        $USER_COMMAND \
        --rm -v ${PWD}:$volume_name \
        docker.io/openapitools/openapi-generator-cli:v4.3.1 generate \
        -i /local/api.json \
        -g ruby \
        -o /local/$1-client \
        --additional-properties=gemName=$1_client,gemLicense="GPLv2+",gemVersion=${VERSION},gemHomepage=https://github.com/pulp/$1 \
        --library=faraday \
        -t /local/templates/ruby \
        --skip-validate-spec \
        --strict-spec=false
fi
if [ $2 = 'typescript' ]
then
    $container_exec run \
        $ULIMIT_COMMAND \
        $USER_COMMAND \
        --rm -v ${PWD}:$volume_name \
        docker.io/openapitools/openapi-generator-cli:v5.2.1 generate \
        -i /local/api.json \
        -g typescript-axios \
        -o /local/$1-client \
	      -t /local/templates/typescript-axios \
        --skip-validate-spec \
        --strict-spec=false
fi

echo ::endgroup::
rm api.json
