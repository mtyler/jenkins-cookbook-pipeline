#!/bin/bash
#if [ "x$WKDIR" = "x" ]; then
#  export WKDIR=$PWD
#fi
BUILD_CONTEXT="`dirname \"$0\"`"              # relative
BUILD_CONTEXT="`( cd \"$BUILD_CONTEXT\" && pwd )`"  # absolutized and normalized
if [ -z "$BUILD_CONTEXT" ] ; then
  exit 1
fi
echo "$BUILD_CONTEXT"

CI_CONTAINER_NAME="blueocean"
CI_IMAGE="mtyler/blueocean"
CONTAINER_VOLUME="jenkins-data"
DOT_CHEF_DIR="/var/chef/.chef"
JENKINS_HOME="/var/jenkins_home"
ADMIN_USR="admin"
ADMIN_PWD="nimda"
GITHUB_TOKEN="$(cat $BUILD_CONTEXT/github-token)"
JENKINS_PROJECT="chef-infra-base"
PROJECT_GIT_REMOTE="git://github.com/mtyler/chef-infra-base.git"
JENKINS_URL="http://localhost:8080/"
KNIFE_RB_FILE="cicdsvc-knife.rb"
CLIENT_KEY_FILE="cicdsvc.pem"
CHEF_SERVER_ADD_HOST="chef-server.test:192.168.33.200"
##
## create an initialization script to create admin user and turn off startup wizard
## comment out this entire file inside the method (to avoid removing code) and then
## uncomment the block
create_basic-setup-groovy() {
    cat > $BUILD_CONTEXT/basic-setup.groovy <<EOL
#!groovy
//
// This script is generated by setup_jenkins
// it is meant to run during init on the Jenkins server to create a user

import hudson.security.*
import jenkins.model.*
import jenkins.branch.BranchProperty;
import jenkins.branch.BranchSource;
import jenkins.branch.DefaultBranchPropertyStrategy;
import jenkins.plugins.git.GitSCMSource;
import org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject;
import com.cloudbees.plugins.credentials.impl.*;
import com.cloudbees.plugins.credentials.*;
import com.cloudbees.plugins.credentials.domains.*;

def out
def config = new HashMap()
def bindings = getBinding()
config.putAll(bindings.getVariables())
out = config['out']
out.println "--> Begin basic-setup.groovy"

def instance = Jenkins.getInstance()

out.println "--> creating local user '${ADMIN_USR}'"
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount('${ADMIN_USR}', '${ADMIN_PWD}')
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

//-- begin add github access token
//Credentials c = (Credentials) new UsernamePasswordCredentialsImpl(CredentialsScope.USER,"github", "Github Access Token", "${ADMIN_USR}", "${GITHUB_TOKEN}")
//SystemCredentialsProvider.getInstance().getStore().addCredentials(Domain.global(), c)
//-- end add github access token

//-- begin create project
def source = new GitSCMSource(null, '${PROJECT_GIT_REMOTE}', "", "*", "", false)
def mp = instance.createProject(WorkflowMultiBranchProject.class, '${JENKINS_PROJECT}')
mp.getSourcesList().add(new BranchSource(source, new DefaultBranchPropertyStrategy(new BranchProperty[0])));
instance.getItemByFullName('${JENKINS_PROJECT}').scheduleBuild()
out.println "--> build scheduled"
//-- end create project

instance.save()
out.println "--> instance saved"
EOL
}

##
## useful docs && commands for creating xml used to create jenkins objects
## credentials docs: https://github.com/jenkinsci/credentials-plugin/blob/master/docs/user.adoc
## java -jar jenkins-cli.jar -auth admin:pwd -s http://localhost:8080/ list-credentials user::user::admin
## java -jar jenkins-cli.jar -auth admin:pwd -s http://localhost:8080/ list-credentials-as-xml user::user::admin
## java -jar jenkins-cli.jar -auth admin:nimda -s http://localhost:8080/ get-credentials-domain-as-xml user::user::admin blueocean-github-domain
##
create_blueocean-github-domain() {
    cat > $BUILD_CONTEXT/blueocean-github-domain.xml <<EOL
    <com.cloudbees.plugins.credentials.domains.Domain plugin="credentials@2.1.18">
      <name>blueocean-github-domain</name>
      <description>blueocean-github-domain to store credentials by BlueOcean</description>
      <specifications>
        <io.jenkins.blueocean.rest.impl.pipeline.credential.BlueOceanDomainSpecification plugin="blueocean-pipeline-scm-api@1.7.1"/>
      </specifications>
    </com.cloudbees.plugins.credentials.domains.Domain>
EOL
}

create_github-credentials() {
cat > $BUILD_CONTEXT/github-credentials.xml <<EOL
      <com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
        <scope>USER</scope>
        <id>github</id>
        <description>GitHub Access Token</description>
        <username>admin</username>
        <password>${GITHUB_TOKEN}</password>
      </com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
EOL
}

##
## create files required for Docker build to copy to container
##
create_last-exec-version() {
    cat > $BUILD_CONTEXT/jenkins.install.InstallUtil.lastExecVersion <<EOL
2.121.3
EOL
}

create_upgrade-wizard-state() {
    cat > $BUILD_CONTEXT/jenkins.install.UpgradeWizard.state <<EOL
2.121.3
EOL
}

create_location-configuration() {
    cat > $BUILD_CONTEXT/jenkins.model.JenkinsLocationConfiguration.xml <<EOL
<?xml version='1.1' encoding='UTF-8'?>
<jenkins.model.JenkinsLocationConfiguration>
 <jenkinsUrl>${JENKINS_URL}</jenkinsUrl>
</jenkins.model.JenkinsLocationConfiguration>
EOL
}

#
# copy knife and pem file to scripts to minimize the size of Docker build context
#
#cp $WKDIR/.chef/$KNIFE_RB_FILE $BUILD_CONTEXT/$KNIFE_RB_FILE
#cp $WKDIR/.chef/$CLIENT_KEY_FILE $BUILD_CONTEXT/$CLIENT_KEY_FILE

# ---------------------------------------------------------------------------
# cleanup any previous images and volumes
# uncomment this block to keep docker clean. helpful when running a lot
#
echo "calling docker stop $CI_CONTAINER_NAME..."
docker stop $CI_CONTAINER_NAME
docker rm -f $CI_CONTAINER_NAME
docker image prune -f
echo "calling docker volume rm $CONTAINER_VOLUME..."
docker volume rm $CONTAINER_VOLUME
#
# ---------------------------------------------------------------------------

# ---
# Begin working with a custom Dockerfile that should be in
# the same directory as this
#
create_basic-setup-groovy
create_last-exec-version
create_upgrade-wizard-state
create_location-configuration

echo "calling docker build -t $CI_IMAGE"
docker build -t $CI_IMAGE \
             --build-arg KNIFE_RB=$KNIFE_RB_FILE \
             --build-arg CLIENT_KEY=$CLIENT_KEY_FILE \
             $BUILD_CONTEXT

if [ ! $? -eq 0 ]; then
  echo ""
  echo "Error: Docker build failed"
  exit 1
fi

echo "calling docker run..."
docker run -u root --rm -d -p 8080:8080 -p 50000:50000 \
           --dns 192.168.1.1 \
           --add-host $CHEF_SERVER_ADD_HOST \
           -v $CONTAINER_VOLUME:$JENKINS_HOME \
           -v /var/run/docker.sock:/var/run/docker.sock \
           --name $CI_CONTAINER_NAME $CI_IMAGE

if [ ! $? -eq 0 ]; then
  echo ""
  echo "Error: Docker run failed"
  exit 1
fi

##
## script needs to wait while server comes up and runs through it's initialization
##
for i in $(seq 1 10); do
  curl -u $ADMIN_USR:$ADMIN_USR -s $JENKINS_URL/user/$ADMIN_USR
  if [ $? -eq 0 ]; then
    echo "$ADMIN_USR found."
    break
  fi
  echo "$ADMIN_USR not created retry in 3..."
  sleep 3
done
## if the admin user wasn't created
curl -u $ADMIN_USR:$ADMIN_USR -s $JENKINS_URL/user/$ADMIN_USR
if [ $? -ne 0 ]; then
  echo "Error: $ADMIN_USR not created. Jenkins cannot be configured."
  echo "The server is probably up and accessible on $JENKINS_URL/blue"
  echo "Pipelines will require manual configuation after logging in"
  exit 1
fi

while true; do
  # wait for service to be available
  ### if [ "$(curl -v --silent http://localhost:8080 2>&1 | grep 'Authentication required')" = "Authentication required" ]; then
  if [ "$(curl -v --silent $JENKINS_URL 2>&1 | grep 'Connected to localhost')" = "Connected to localhost" ]; then
    echo "..."
    sleep 3
  else
    ## retry until jenkins-cli is available
    while true; do
      curl --fail $JENKINS_URL/jnlpJars/jenkins-cli.jar --output jenkins-cli.jar 2>&1 \
      && break \
      || echo "Download failed for jenkins-cli.jar retrying..." \
      && sleep 3
    done
    echo "client downloaded..."
sleep 3
    if [ "x$GITHUB_TOKEN" = "x" ]; then
      echo "Github Access Token is not set, blueocean pipeline will need to be created manually.
            Be sure to create $WKDIR/github-token with a valid token.
            https://github.com/settings/tokens"
      exit 1
    else
      ## ----------------------------------------------------------------------
      ## Begin creating a github access token
      ## https://github.com/jenkinsci/credentials-plugin/blob/master/docs/user.adoc
      ##
      echo "Creating github credentials..."
## TODO replace these jenkins-cli commands with the blueocean rest calls
## TODO -OR- this should be moved to the init.d.groovy script to keep things together
##  curl -v -u admin:admin -d '{"accessToken": boo"}' -H "Content-Type:application/json" -XPUT http://localhost:8080/jenkins/blue/rest/organizations/jenkins/scm/github/validate
## from: https://github.com/jenkinsci/blueocean-plugin/tree/master/blueocean-rest#multibranch-pipeline-api
## curl -v -u $ADMIN_USR:$ADMIN_PWD -d '{"accessToken": "$GITHUB_TOKEN"}' -H "Content-Type:application/json" -XPUT http://localhost:8080/jenkins/blue/rest/organizations/jenkins/scm/github/validate


      create_github-credentials
      create_blueocean-github-domain
      java -jar ./jenkins-cli.jar -s $JENKINS_URL who-am-i --username $ADMIN_USR --password $ADMIN_PWD
      if [ $? -eq 0 ]; then echo "Connections successful!"; fi
      java -jar ./jenkins-cli.jar -auth $ADMIN_USR:$ADMIN_PWD -s $JENKINS_URL create-credentials-domain-by-xml user::user::$ADMIN_USR < $BUILD_CONTEXT/blueocean-github-domain.xml
      if [ $? -eq 0 ]; then echo "Domain created!"; fi
      java -jar ./jenkins-cli.jar -auth $ADMIN_USR:$ADMIN_PWD -s $JENKINS_URL create-credentials-by-xml user::user::$ADMIN_USR blueocean-github-domain < $BUILD_CONTEXT/github-credentials.xml
      if [ $? -eq 0 ]; then echo "Github Access Token added!"; fi


      ##
      ## End creating github access token
      ## ----------------------------------------------------------------------

    fi
    echo "Jenkins started on $JENKINS_URL"
    echo "Startup credentials user: $ADMIN_USR pwd: $ADMIN_PWD"
    break
  fi
done

exit 0
