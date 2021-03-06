#!/bin/bash
# Script for setting up the Tweeter demo in DC/OS
#
# Usage: DCOS_URL=http://<IP-address> DCOS_EE=[true/false] bash cli_script.sh
#
# Requirements:
#   - DC/OS cluster with 1 public slave and 5 private slaves with
#       or without superuser set
#   - DCOS CLI installed on localhost
#   - DCOS_EE set to true or false
#   - DCOS_URL set to DCOS master URL
#
# If no user credentials are supplied, the following will be used:
#   Enterprise:
#     - AWS default bootstrapuser/deleteme
#     - Override with DCOS_USER & DCOS_PW
#   OSS:
#     - The token hard-coded below for mesosphere.user@gmail.com
#         password: unicornsarereal
#     - Override with DCOS_AUTH_TOKEN
set -o errexit

ci_auth_token='eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6Ik9UQkVOakZFTWtWQ09VRTRPRVpGTlRNMFJrWXlRa015Tnprd1JrSkVRemRCTWpBM1FqYzVOZyJ9.eyJlbWFpbCI6Im1lc29zcGhlcmUudXNlckBnbWFpbC5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiaXNzIjoiaHR0cHM6Ly9kY29zLmF1dGgwLmNvbS8iLCJzdWIiOiJnb29nbGUtb2F1dGgyfDEwMzI4NjMzNTExMTExNTM2NTg4MyIsImF1ZCI6IjN5RjVUT1N6ZGxJNDVRMXhzcHh6ZW9HQmU5Zk54bTltIiwiZXhwIjoxNDcxNDY3ODI0LCJpYXQiOjE0NzEwMzU4MjR9.imfN3JDF-XpX_PT9YOgle8bHTBdPOZJ-G4AxvUennppOkcwe8XzTcU-s6bmo47eHPSCqBGHb1rH8m8kIRkrOQtOraISqqlkf5fV8LYSHirX6fSSluUhKPEmyPueipSFCvNxF3OerG6PCvM-VC_pSINIKgZi_o6sDN06r3AfcDjnU1XutrHcjfP-Jvv3p7l550NtMjsXq4hIciu-tf8Nbsh8lz6dHimIbzf-_g6l3UJSxRt-ota0H7myRtSLaP72YB7R369D0xqKxDQYKmkV0LJtNw_AsIsMvBISWH3X7LKfd1O0qSAioP3JODjVlgO916MnHG-wZW788nIPcGxfEGA'
DCOS_AUTH_TOKEN=${DCOS_AUTH_TOKEN:=$ci_auth_token}
DCOS_USER=${DCOS_USER:='bootstrapuser'}
DCOS_PW=${DCOS_PW:='deleteme'}

is_running() {
    status=`dcos marathon app list | grep $1 | awk '{print $6}'`
    if [ $status == '---' ]; then
        return 0
    else
        return 1
    fi
}

wait_for_deployment() {
    for service in $*; do
        until is_running $service; do
            echo "Wait for $service to finsh deploying..."
            sleep 3
        done
    done
}

ee_login() {
cat <<EOF | expect -
spawn dcos auth login
expect "username:"
send "$DCOS_USER\n"
expect "password:"
send "$DCOS_PW\n"
expect eof
EOF
}

oss_login() {
cat <<EOF | expect -
spawn dcos auth login
expect "token:"
send "$DCOS_AUTH_TOKEN\n"
expect eof
EOF
}

# Check DC/OS CLI is actually installed
dcos --help &> /dev/null || ( echo 'DC/OS must be installed!' && exit 1 )

# Setup access to the desired DCOS cluster and install marathon lb
dcos config set core.dcos_url "${DCOS_URL:?Error: DCOS_URL must be set!}"
if ${DCOS_EE:?'Error: DCOS_EE must be set to true or false'}; then
    echo Starting DC/OS Enterprise Demo
    echo Override default credentials with DCOS_USER and DCOS_PW
    ee_login
    cat <<EOF > get_sa.json
{
  "id": "/saread",
  "cmd": "cat /run/dcos/etc/mesos/agent_service_account.json\nsleep 36000",
  "instances": 1,
  "cpus": 0.1,
  "mem": 32,
  "user": "root"
}
EOF
    dcos marathon app add get_sa.json
    wait_for_deployment saread
    # This string will be used as a JSON value, so escape "
    sa_token=`dcos task log --lines=1 saread | sed 's/"/\\\\"/g'`
    dcos marathon app remove saread
    # Get auth headers to do calls outside of dcos CLI (secrets)
    cat <<EOF > login.json
{
  "uid": "$DCOS_USER",
  "password": "$DCOS_PW"
}
EOF
    auth_r=`curl -kfSslv -H 'content-type: application/json' -X POST -d @login.json $DCOS_URL/acs/api/v1/auth/login`
    echo $auth_r
    auth_t=`echo $auth_r | awk '{print $3}' | tr -d '"'`
    auth_h="Authorization: token=$auth_t"
    cat <<EOF > marathon-lb-secret.json
{
  "value": "$sa_token"
}
EOF
    curl -kfSslv -X PUT -H "$auth_h" -d @marathon-lb-secret.json $DCOS_URL/secrets/v1/secret/default/marathon-lb
    cat <<EOF > options.json
{
  "marathon-lb": {
    "secret_name": "marathon-lb"
  }
}
EOF
    dcos package install --yes --options=options.json marathon-lb
else
    echo Starting DC/OS OSS Demo
    echo Override default credentials with DCOS_AUTH_TOKEN
    oss_login
    dcos package install --yes marathon-lb
fi
dcos package install --yes cassandra
dcos package install --yes kafka
dcos package install --yes zeppelin

# query until services are listed as running
wait_for_deployment marathon-lb cassandra kafka zeppelin

# once running, deploy tweeter app and then post to it
dcos marathon app add tweeter.json
wait_for_deployment tweeter

dcos marathon app add post-tweets.json
wait_for_deployment post-tweets

# get the public IP of the public node if unset
cat <<EOF > public-ip.json
{
  "id": "/public-ip",
  "cmd": "curl http://169.254.169.254/latest/meta-data/public-ipv4 && sleep 3600",
  "cpus": 0.25,
  "mem": 32,
  "instances": 1,
  "acceptedResourceRoles": [
    "slave_public"
  ]
}
EOF
dcos marathon app add public-ip.json
wait_for_deployment public-ip
public_ip=`dcos task log --lines=1 public-ip`
dcos marathon app remove public-ip

# Now that tweets have been posted and the site is up, make sure it all works:
tweet_count=`curl -sSlvf $public_ip:10000 | grep 'class="tweet-content"' | wc -l`
if [ $tweet_count > 0 ]; then
    echo "Tweeter is up and running; $tweet_count tweets shown"
    exit 0
else
    echo "Failure: No tweets found!"
    exit 1
fi
