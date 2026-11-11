#!/bin/bash

# Start script that will wait for mautic to be installed before setting up cron jobs
/startup/wait_for_mautic_install.sh

mkdir -p /opt/mautic/cron

if [ ! -f /opt/mautic/cron/mautic  ]; then
  cp -p /templates/mautic_cron /opt/mautic/cron/mautic
fi

# register the crontab file for the www-data user
crontab -u www-data /opt/mautic/cron/mautic

# if /tmp/stdout exists clear it out
if [ ! -p /tmp/stdout ]; then
  rm -f /tmp/stdout
fi
# create the fifo file to be able to redirect cron output for non-root users
mkfifo /tmp/stdout
chmod 777 /tmp/stdout

# Les tâches cron ne reçoivent pas l'environnement du conteneur : elles lisent
# /tmp/cron.env (BASH_ENV du crontab). On y met les réglages PHP ET les
# réglages MAUTIC_* de l'espace. Constaté le 12/11 : sans les MAUTIC_*, les
# tâches (envoi des campagnes, e-mails programmés) ignoraient la file e-mail
# et le domaine d'envoi de l'espace, et retombaient sur des valeurs
# périmées de local.php : les e-mails partaient dans une file que personne
# ne lisait. Le fichier contient des secrets de l'espace : lisible par
# www-data seulement (les tâches tournent sous ce compte).
# printf %q échappe guillemets, $ et retours à la ligne : le fichier se relit
# toujours sans erreur.
: > /tmp/cron.env
while IFS= read -r -d '' VARIABLE; do
  NOM="${VARIABLE%%=*}"
  case "$NOM" in
    PHP_INI_VALUE_*|MAUTIC_*) printf 'export %s=%q\n' "$NOM" "${VARIABLE#*=}" >> /tmp/cron.env ;;
  esac
done < <(env -0)
chown root:www-data /tmp/cron.env
chmod 640 /tmp/cron.env

# run cron and print the output
cron -f | tail -f /tmp/stdout
