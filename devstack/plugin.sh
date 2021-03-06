#!/usr/bin/env bash
# Copyright 2016 Massachusetts Open Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

FEDERATION_SCRIPTS=$DEST/federation/devstack/scripts
FEDERATION_FILES=$DEST/federation/devstack/files

function install_idp(){
    if is_ubuntu; then
        install_package xmlsec1 python-pip
    fi
    sudo pip install pysaml2
}

function configure_idp(){
    iniset $KEYSTONE_CONF saml certfile "/etc/keystone/ssl/certs/ca.pem"
    iniset $KEYSTONE_CONF saml keyfile "/etc/keystone/ssl/private/cakey.pem"
    iniset $KEYSTONE_CONF saml idp_entity_id "http://$HOST_IP:5000/v3/OS-FEDERATION/saml2/idp"
    iniset $KEYSTONE_CONF saml idp_sso_endpoint "http://$HOST_IP:5000/v3/OS-FEDERATION/saml2/sso"
    iniset $KEYSTONE_CONF saml idp_metadata_path "/etc/keystone/keystone_idp_metadata.xml"

    keystone-manage pki_setup
    keystone-manage saml_idp_metadata > /etc/keystone/keystone_idp_metadata.xml

    restart_apache_server
}

function install_sp() {
    if is_ubuntu; then
        install_package libxml2-dev libxslt-dev python-dev xmlsec1 \
            libapache2-mod-shib2
    else
        sudo yum-config-manager --add-repo \
            http://download.opensuse.org/repositories/security://shibboleth/CentOS_7/security:shibboleth.repo
        install_package xmlsec1 xmlsec1-openssl libxml2-devel libxslt-devel \
            python-devel mod_ssl shibboleth
    fi

    sudo pip install pysaml2 lxml
}

function configure_sp() {
    if is_ubuntu; then
        sudo shib-keygen -f
    else
        ./etc/shibboleth/keygen.sh -f
    fi

    local keystone_apache_conf=$(apache_site_config_for keystone)
    sudo sed -i "/\<VirtualHost \*\:5000\>/a WSGIScriptAliasMatch \^(/v3/OS-FEDERATION/identity_providers/.\*?/protocols/.\*?/auth)$ /var/www/keystone/main/\$1" $keystone_apache_conf
    cat $FEDERATION_FILES/shib_handler.txt | sudo tee -a $keystone_apache_conf

    sudo cp $FEDERATION_FILES/attribute-map.xml /etc/shibboleth/attribute-map.xml
    sudo cp $FEDERATION_FILES/shibboleth2.xml /etc/shibboleth/shibboleth2.xml
    sudo sed -e "
        s|%IDP_REMOTE_ID%|$IDP_REMOTE_ID|g;
        s|%IDP_METADATA%|$IDP_METADATA|g;
    " -i /etc/shibboleth/shibboleth2.xml

    iniset $KEYSTONE_CONF auth methods "external,password,token,oauth1,saml2"
    iniset $KEYSTONE_CONF auth saml2 "keystone.auth.plugins.mapped.Mapped"

    sudo a2enmod shib2

    restart_apache_server
    restart_shibboleth

    local federated_user=$(get_or_create_user federated_user)
    local federated_project=$(get_or_create_project federated_project)
    local federated_group=$(get_or_create_group federated_group default)
    local member_role=$(get_or_create_role _member_)

    openstack role add --project $federated_project --user $federated_user $member_role
    openstack role add --project $federated_project --group $federated_group $member_role

    openstack --os-identity-api-version 3 identity provider create \
        --remote-id $IDP_REMOTE_ID $IDP_ID
    openstack --os-identity-api-version 3 mapping create \
        --rules $FEDERATION_FILES/mapping.txt mapping1
    openstack --os-identity-api-version 3 federation protocol create \
        --identity-provider $IDP_ID --mapping mapping1 saml2
}

function restart_shibboleth() {
    if is_ubuntu; then
        restart_service shibd
    fi
}
if [[ "$1" == "stack" && "$2" == "install" ]]; then
    if is_service_enabled k2k-idp; then
        install_idp
    fi

    if is_service_enabled federation-sp; then
        install_sp
    fi

elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
    if is_service_enabled k2k-idp; then
        configure_idp
    fi

    if is_service_enabled federation-sp; then
        configure_sp
    fi

elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
    # Initialize and start the template service
    :
fi

if [[ "$1" == "unstack" ]]; then
    # Shut down template services
    # no-op
    :
fi

if [[ "$1" == "clean" ]]; then
    # Remove state and transient data
    # Remember clean.sh first calls unstack.sh
    # no-op
    :
fi