#!/bin/bash

if [ -z "$1" ]; then
    echo "Ús: $0 <contrasenya>"
    exit 1
fi

PASSWORD="$1"

LOGFILE="/var/log/automatitzacio.log"

mkdir -p /var/log
touch "$LOGFILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log_and_run() {
    log "EXEC: $*"
    bash -c "$*" >>"$LOGFILE" 2>&1
}


log "======================="
log " Instal·lació OpenLDAP "
log "======================="

log "Actualitzant i instal·lant dependències..."

log_and_run "dnf install -y \
cyrus-sasl-devel make libtool autoconf libtool-ltdl-devel \
openssl-devel libdb-devel tar gcc perl perl-devel wget vim"

log "Creant script instal·lador /tmp/install-ldap.sh..."

cat >/tmp/install-ldap.sh <<'EOL'
#!/bin/bash
set -e

LOGFILE="/var/log/openldap-install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }
log_and_run() { log "EXEC: $*"; bash -c "$*" >>"$LOGFILE" 2>&1; }

VER="2.6.3"

cd /tmp
log "Descarregant OpenLDAP $VER"
log_and_run "wget ftp://ftp.openldap.org/pub/OpenLDAP/openldap-release/openldap-$VER.tgz"

log "Descomprimint"
log_and_run "tar xzf openldap-$VER.tgz"

cd openldap-$VER

log "Executant configure..."
log_and_run "./configure --prefix=/usr --sysconfdir=/etc --disable-static \
--enable-debug --with-tls=openssl --with-cyrus-sasl --enable-dynamic \
--enable-crypt --enable-spasswd --enable-slapd --enable-modules \
--enable-rlookups --disable-sql --enable-ppolicy --enable-syslog"

log "Compilant..."
log_and_run "make depend"
log_and_run "make"

log "Compilant mòdul sha2..."
cd contrib/slapd-modules/passwd/sha2
log_and_run "make"

cd ../../../..
log "Instal·lant OpenLDAP"
log_and_run "make install"

cd contrib/slapd-modules/passwd/sha2
log "Instal·lant modul sha2"
log_and_run "make install"

log "Instal·lació completada correctament."
EOL

chmod +x /tmp/install-ldap.sh

log "Executant instal·ladors..."
log_and_run "bash /tmp/install-ldap.sh"





log "=============================="
log " Configuració post-instal·lació OpenLDAP "
log "=============================="

log "Creant grup ldap (gid 55)..."
groupadd -g 55 ldap >>"$LOGFILE" 2>&1 || log "El grup ja existeix."

log "Creant usuari ldap (uid 55)..."
useradd -r -M -d /var/lib/openldap -u 55 -g 55 -s /usr/sbin/nologin ldap >>"$LOGFILE" 2>&1 || log "L'usuari ja existeix."

log "Creant directoris necessaris..."
mkdir -p /var/lib/openldap >>"$LOGFILE" 2>&1
mkdir -p /etc/openldap/slapd.d >>"$LOGFILE" 2>&1

log "Atorgant permisos..."
chown -R ldap:ldap /var/lib/openldap >>"$LOGFILE" 2>&1
chown root:ldap /etc/openldap/slapd.conf >>"$LOGFILE" 2>&1
chmod 640 /etc/openldap/slapd.conf >>"$LOGFILE" 2>&1

log "Creant servei systemd slapd..."

cat >/etc/systemd/system/slapd.service << 'EOL'
[Unit]
Description=OpenLDAP Server Daemon
After=syslog.target network-online.target
Documentation=man:slapd
Documentation=man:slapd-mdb

[Service]
Type=forking
PIDFile=/var/lib/openldap/slapd.pid
Environment="SLAPD_URLS=ldap:/// ldapi:/// ldaps:///"
Environment="SLAPD_OPTIONS=-F /etc/openldap/slapd.d"
ExecStart=/usr/libexec/slapd -u ldap -g ldap -h ${SLAPD_URLS} $SLAPD_OPTIONS

[Install]
WantedBy=multi-user.target
EOL

log "Habilitant i recarregant systemd..."
systemctl daemon-reload >>"$LOGFILE" 2>&1
systemctl enable slapd >>"$LOGFILE" 2>&1

log "Generant hash SSHA512 per la contrasenya..."

HASH=$(slappasswd -h "{SSHA512}" \
    -o module-load=pw-sha2.la \
    -o module-path=/usr/local/libexec/openldap \
    -s "$PASSWORD")

log "Hash generat: $HASH"

echo
echo "Hash generat per OpenLDAP:"
echo "$HASH"
echo

log "Creant /etc/openldap/slapd.ldif..."

cat >/etc/openldap/slapd.ldif <<EOL
dn: cn=config
objectClass: olcGlobal
cn: config
olcArgsFile: /var/lib/openldap/slapd.args
olcPidFile: /var/lib/openldap/slapd.pid
olcTLSCipherSuite: TLSv1.2:HIGH:\!aNULL:\!eNULL
olcTLSProtocolMin: 3.3

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /usr/libexec/openldap
olcModuleload: back_mdb.la

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /usr/local/libexec/openldap
olcModuleload: pw-sha2.la

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/nis.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif

dn: olcDatabase=frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: frontend
olcPasswordHash: $HASH
olcAccess: to dn.base="cn=Subschema" by * read
olcAccess: to *
  by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by * none

dn: olcDatabase=config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: config
olcRootDN: cn=config
olcAccess: to *
  by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by * none
EOL

log "Importat slapd.ldif a slapd.d..."

cd /etc/openldap/
slapadd -n 0 -F /etc/openldap/slapd.d -l /etc/openldap/slapd.ldif >>"$LOGFILE" 2>&1

chown -R ldap:ldap /etc/openldap/slapd.d

log "Iniciant servei slapd..."

systemctl daemon-reload
systemctl enable --now slapd

BASE="dc=amsa,dc=udl,dc=cat"

log "Creant rootdn.ldif..."

cat >/etc/openldap/rootdn.ldif <<EOL
dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcDbMaxSize: 42949672960
olcDbDirectory: /var/lib/openldap
olcSuffix: $BASE
olcRootDN: cn=admin,$BASE
olcRootPW: $HASH
olcDbIndex: uid pres,eq
olcDbIndex: cn,sn pres,eq,approx,sub
olcDbIndex: mail pres,eq,sub
olcDbIndex: objectClass pres,eq
olcDbIndex: loginShell pres,eq
olcAccess: to attrs=userPassword,shadowLastChange,shadowExpire
  by self write
  by anonymous auth
  by dn.subtree="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by dn.subtree="ou=system,$BASE" read
  by * none
olcAccess: to dn.subtree="ou=system,$BASE"
  by dn.subtree="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by * none
olcAccess: to dn.subtree="$BASE"
  by dn.subtree="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by users read
  by * none
EOL

log "Afegint base de dades MDB a cn=config..."

ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/rootdn.ldif >>"$LOGFILE" 2>&1

log "Creant basedn.ldif..."

DC="amsa"

cat >/etc/openldap/basedn.ldif <<EOL
dn: $BASE
objectClass: dcObject
objectClass: organization
objectClass: top
o: AMSA
dc: $DC

dn: ou=groups,$BASE
objectClass: organizationalUnit
ou: groups

dn: ou=users,$BASE
objectClass: organizationalUnit
ou: users

dn: ou=system,$BASE
objectClass: organizationalUnit
ou: system
EOL

log "Carregant estructura base..."

ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/basedn.ldif >>"$LOGFILE" 2>&1

log "Creant usuaris i grups base..."

cat >/etc/openldap/users.ldif <<EOL
dn: cn=osproxy,ou=system,$BASE
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: osproxy
userPassword: $HASH
description: OS proxy for resolving UIDs/GIDs
EOL

groups=("programadors" "dissenyadors")
gids=("5000" "5001")
users=("ramon" "manel")
sns=("mateo" "lopez")
uids=("4000" "4001")

# Grups
for (( j=0; j<${#groups[@]}; j++ )); do
cat >>/etc/openldap/users.ldif <<EOL
dn: cn=${groups[$j]},ou=groups,$BASE
objectClass: posixGroup
cn: ${groups[$j]}
gidNumber: ${gids[$j]}
EOL
done

# Usuaris
for (( j=0; j<${#users[@]}; j++ )); do
cat >>/etc/openldap/users.ldif <<EOL
dn: uid=${users[$j]},ou=users,$BASE
objectClass: posixAccount
objectClass: shadowAccount
objectClass: inetOrgPerson
cn: ${users[$j]}
sn: ${sns[$j]}
uidNumber: ${uids[$j]}
gidNumber: ${uids[$j]}
homeDirectory: /home/${users[$j]}
loginShell: /bin/sh
EOL
done

log "Carregant usuaris i grups..."

ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/users.ldif >>"$LOGFILE" 2>&1


PATH_PKI="/etc/pki/tls"
HOSTNAME="$(hostname -f)"

log "Generant certificats TLS..."

openssl req -days 500 -newkey rsa:4096 \
    -keyout "$PATH_PKI/ldapkey.pem" -nodes \
    -sha256 -x509 -out "$PATH_PKI/ldapcert.pem" \
    -subj "/C=ES/ST=Spain/L=Igualada/O=UdL/OU=IT/CN=$HOSTNAME/emailAddress=admin@udl.cat" \
    >>"$LOGFILE" 2>&1

chown ldap:ldap "$PATH_PKI/ldapkey.pem"
chmod 400 "$PATH_PKI/ldapkey.pem"
cp "$PATH_PKI/ldapcert.pem" "$PATH_PKI/cacerts.pem"


log "Creant configuració TLS..."

cat >/etc/openldap/add-tls.ldif <<EOL
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: $PATH_PKI/cacerts.pem
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $PATH_PKI/ldapkey.pem
-
add: olcTLSCertificateFile
olcTLSCertificateFile: $PATH_PKI/ldapcert.pem
EOL


log "Aplicat TLS a cn=config..."

ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/add-tls.ldif >>"$LOGFILE" 2>&1



log "Configuració post-instal·lació completada."


log "Instal·lació finalitzada."
echo "Log a: $LOGFILE"
echo "Comprovacions:"

