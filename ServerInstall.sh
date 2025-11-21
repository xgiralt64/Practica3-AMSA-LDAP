#!/bin/bash

LOGFILE="/var/log/openldap-install.log"

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

log "Comprovació de directoris:"

log_and_run "ls -la /etc/openldap/"
log_and_run "ls -la /usr/local/libexec/openldap/"

log "✔ Instal·lació finalitzada."
echo
echo "Log complet disponible a: $LOGFILE"
echo "Comprovacions:"
echo "  sudo ls -la /etc/openldap/"
echo "  sudo ls -la /usr/local/libexec/openldap/"
