#!/bin/bash

source /startup/logger.sh

# prepare mautic with test data
if [ "$DOCKER_MAUTIC_LOAD_TEST_DATA" = "true" ]; then
  su -s /bin/bash $MAUTIC_WWW_USER -c "php $MAUTIC_CONSOLE doctrine:migrations:sync-metadata-storage"
  # mautic installation with dummy password and email, as the next step (doctrine:fixtures:load) will overwrite those
  su -s /bin/bash $MAUTIC_WWW_USER -c "php $MAUTIC_CONSOLE mautic:install --force --admin_email willchange@mautic.org --admin_password willchange http://localhost"
  su -s /bin/bash $MAUTIC_WWW_USER -c "php $MAUTIC_CONSOLE doctrine:fixtures:load -n"
fi

# run migrations
if php -r "include('${MAUTIC_VOLUME_CONFIG}/local.php'); exit(!empty(\$parameters['db_driver']) && !empty(\$parameters['site_url']) ? 0 : 1);"; then
  log "[${DOCKER_MAUTIC_ROLE}]: Mautic is already installed, running migrations..."
  su -s /bin/bash $MAUTIC_WWW_USER -c "php $MAUTIC_CONSOLE doctrine:migrations:migrate -n"
  # White-label : purge les permissions plugin/marketplace des rôles tenant.
  # Non bloquant : la commande n'existe que dans l'image eweb.
  su -s /bin/bash $MAUTIC_WWW_USER -c "php $MAUTIC_CONSOLE mautic:saas:roles:harden" \
    || log "[${DOCKER_MAUTIC_ROLE}]: mautic:saas:roles:harden indisponible (non bloquant)."
  # White-label : le volume media/images a figé les icônes Mautic du premier
  # démarrage et masque celles de l'image (flash du vieux favicon dans
  # l'onglet). On resynchronise les actifs de marque à chaque boot.
  for BRAND_ASSET in favicon.ico apple-touch-icon.png; do
    if [ -f "/var/www/html/app/assets/images/${BRAND_ASSET}" ]; then
      cp -f "/var/www/html/app/assets/images/${BRAND_ASSET}" "/var/www/html/media/images/${BRAND_ASSET}" 2>/dev/null \
        || log "[${DOCKER_MAUTIC_ROLE}]: copie de ${BRAND_ASSET} impossible (non bloquant)."
    fi
  done
else
  log "[${DOCKER_MAUTIC_ROLE}]: Mautic is not installed, skipping migrations."
fi

# Le ?v des assets se fige : le conteneur Symfony compilé du tenant peut
# survivre aux déploiements (cache persistant — même famille de piège que
# les icônes media/images ci-dessus) et la version des assets reste celle
# du PREMIER boot (constaté : ?v inchangé sur 5 déploiements, stable par
# tenant). À chaque boot, si la release de l'image (app/release.txt,
# unique par build) diffère de celle qui a compilé le cache, on purge —
# la recompilation au premier hit lit la nouvelle release.
RELEASE_FILE=/var/www/html/app/release.txt
CACHE_MARK=/var/www/html/var/cache/sendly-release.txt
if [ -f "$RELEASE_FILE" ]; then
  if [ ! -f "$CACHE_MARK" ] || ! cmp -s "$RELEASE_FILE" "$CACHE_MARK"; then
    log "[${DOCKER_MAUTIC_ROLE}]: nouvelle release $(cat "$RELEASE_FILE") — purge du cache Symfony."
    rm -rf /var/www/html/var/cache/prod
    mkdir -p /var/www/html/var/cache
    cp "$RELEASE_FILE" "$CACHE_MARK" 2>/dev/null || true
    chown -R www-data:www-data /var/www/html/var/cache 2>/dev/null || true
  fi
fi

# start the proper service based on FLAVOUR
if [ "${FLAVOUR}" = "fpm" ]; then \
  php-fpm
elif [ "${FLAVOUR}" = "apache" ]; then \
  apache2-foreground
else
  log "[${DOCKER_MAUTIC_ROLE}]: FLAVOUR variable is not set correctly, exiting."
  exit 1
fi