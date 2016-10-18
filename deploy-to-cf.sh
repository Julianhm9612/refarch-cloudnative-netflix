#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

#################################################################################
# Configuration Data
#################################################################################

#This can be updated to use any string which will guarantee global uniqueness across your region (username, favorite cat, etc.)
SERVICE_SUFFIX=${RANDOM}

#The name of the user-provided-service we will create to connect to Service Discovery servers
SERVICE_DISCOVERY_UPS="eureka-service-discovery"
#The name of the user-provided-service we will create to connect to Config servers
CONFIG_SERVER_UPS="config-server"
#The name of the user-provided-service we will create to connect to zipkin
ZIPKIN_SERVER_UPS="zipkin-server"

# The domain associated with your Bluemix region
DOMAIN="mybluemix.net"
#DOMAIN="eu-gb.mybluemix.net"
#DOMAIN="au-syd.mybluemix.net"

#IBM Cloud Architecture GitHub Repository.  This should be changed for forked repositories.
GITHUB_ORG="ibm-cloud-architecture"

#All required repositories
REQUIRED_REPOS=(
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-netflix-eureka.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-zipkin.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-spring-config.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-netflix-turbine.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-netflix-zuul.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-wfd-appetizer.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-wfd-entree.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-wfd-dessert.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-wfd-menu.git
    https://github.com/${GITHUB_ORG}/refarch-cloudnative-wfd-ui.git
)

#################################################################################
# Deployment Code
#################################################################################

#Build all required repositories as a peer of the current directory (root microservices-refapp-netflix repository)
for REPO in ${REQUIRED_REPOS[@]}; do

  PROJECT=$(echo ${REPO} | cut -d/ -f5 | cut -d. -f1)
  echo -e "\nStarting ${PROJECT} project"

  cd ../${PROJECT}

  # Determein which JAR file we should use (since we have both Gradle and Maven possibilities)
  RUNNABLE_JAR="$(find . -name "*-SNAPSHOT.jar" | sed -n 1p)"

  # Create the route ahead of time to control access
  COMPONENT=${PROJECT#refarch-cloudnative-}
  CURRENT_SPACE=$(cf target | grep "Space:" | awk '{print $2}')
  SERVICE_ROUTE="${COMPONENT}-${SERVICE_SUFFIX}"

  cf create-route ${CURRENT_SPACE} ${DOMAIN} --hostname ${SERVICE_ROUTE}

  # Push application code
  if [[ ${COMPONENT} == *"netflix-eureka"* ]]; then
    # Push Eureka application code, leveraging metadata from manifest.yml
    cf push \
      -p ${RUNNABLE_JAR} \
      -d ${DOMAIN} \
      -n ${SERVICE_ROUTE}
    RUN_RESULT=$?

    # Create a user-provided-service instance of Eureka for easier binding
    CHECK_SERVICE=$(cf service ${SERVICE_DISCOVERY_UPS})
    if [[ "$?" == "0" ]]; then
      cf delete-service -f ${SERVICE_DISCOVERY_UPS}
    fi
    cf create-user-provided-service ${SERVICE_DISCOVERY_UPS} -p "{\"uri\": \"http://${SERVICE_ROUTE}.${DOMAIN}/eureka/\"}"

  elif [[ ${COMPONENT} == *"spring-config"* ]]; then
    # Push Config Server application code, leveraging metadata from manifest.yml
    cf push \
      -p ${RUNNABLE_JAR} \
      -d ${DOMAIN} \
      -n ${SERVICE_ROUTE} \
      --no-start
    RUN_RESULT=$?

    cf bind-service ${COMPONENT} ${SERVICE_DISCOVERY_UPS}
    cf bind-service ${COMPONENT} ${ZIPKIN_SERVER_UPS}
    cf restage ${COMPONENT}
    cf start ${COMPONENT}

    # Create a user-provided-service instance of Config Server for easier binding
    CHECK_SERVICE=$(cf service ${CONFIG_SERVER_UPS})
    if [[ "$?" == "0" ]]; then
      cf delete-service -f ${CONFIG_SERVER_UPS}
    fi
    cf create-user-provided-service ${CONFIG_SERVER_UPS} -p "{\"uri\": \"http://${SERVICE_ROUTE}.${DOMAIN}/\"}"

  elif [[ ${COMPONENT} == *"zipkin"* ]]; then
    # zipkin jar is downloaded, not built by us:
    RUNNABLE_JAR="$(find . -name "zipkin.jar" | sed -n 1p)"
    # Push zipkin server, leveraging metadata from manifest.yml
    cf push \
      -p ${RUNNABLE_JAR} \
      -d ${DOMAIN} \
      -n ${SERVICE_ROUTE} \
      --no-start
    RUN_RESULT=$?

    cf bind-service ${COMPONENT} ${SERVICE_DISCOVERY_UPS}
    cf restage ${COMPONENT}
    cf start ${COMPONENT}

    # Create a user-provided-service instance of zipkin for easier binding
    CHECK_SERVICE=$(cf service ${ZIPKIN_SERVER_UPS})
    if [[ "$?" == "0" ]]; then
      cf delete-service -f ${ZIPKIN_SERVER_UPS}
    fi
    cf create-user-provided-service ${ZIPKIN_SERVER_UPS} -p "{\"uri\": \"http://${SERVICE_ROUTE}.${DOMAIN}/\"}"

  else
    # Push microservice component code, leveraging metadata from manifest.yml
    cf push \
      -p ${RUNNABLE_JAR} \
      -d ${DOMAIN} \
      -n ${SERVICE_ROUTE} \
      --no-start

    cf set-env ${COMPONENT} SPRING_PROFILES_ACTIVE cloud

    cf bind-service ${COMPONENT} ${SERVICE_DISCOVERY_UPS}
    cf bind-service ${COMPONENT} ${CONFIG_SERVER_UPS}
    cf bind-service ${COMPONENT} ${ZIPKIN_SERVER_UPS}
    cf start ${COMPONENT}
    RUN_RESULT=$?
  fi

  if [ ${RUN_RESULT} -ne 0 ]; then
    echo ${PROJECT}" failed to start successfully.  Check logs in the local project directory for more details."
    exit 1
  fi
  cd $SCRIPTDIR
done

cf apps
