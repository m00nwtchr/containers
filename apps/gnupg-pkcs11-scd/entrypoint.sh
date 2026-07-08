#!/usr/bin/env bash
exec gnupg-pkcs11-scd --multi-server \
  --homedir /var/lib/gnupg-pkcs11-scd
