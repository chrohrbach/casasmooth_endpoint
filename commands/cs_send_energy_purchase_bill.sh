#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.1.1
#
# This script reads the energy purchase logs for each user, calculates the total cost, and sends an email with the bill details.
#

include="/config/casasmooth/lib/cs_library.sh"
if ! source "${include}"; then
  echo "ERROR: Failed to source ${include}"
  exit 1
fi

# Get the billing month (previous month)
month=$(date -d "-1 month" '+%Y-%m')

log_dir="${cs_logs}/energy_purchases"

# Get admin email from states yaml
admin_email=$(awk '/cs_user_mail:/ {gsub("cs_user_mail:[ ]*", ""); print $0}' ${cs_locals}/cs_states.yaml | tr -d '"')

for user_dir in "$log_dir"/*/; do
  email=$(basename "$user_dir")
  bill_file="${user_dir}/${month}.csv"
  [ -f "$bill_file" ] || continue

  # Read transactions, skip header
  transactions=$(tail -n +2 "$bill_file")
  total_cost=$(echo "$transactions" | awk -F',' '{sum+=$6} END {printf "%.2f", sum}')

  # Préparer le corps du mail en français
  body="Bonjour,\n\nVoici le récapitulatif de votre consommation d'énergie pour le mois de $month :\n\n"
  body+="Date, Appareil, kWh, Coût (CHF)\n"
  while IFS=',' read -r ts guid eid ename kwh cost stime etime; do
    body+="${ts%%T*}, $ename, $kwh, $cost\n"
  done <<< "$transactions"
  body+="\nCoût total : CHF $total_cost\n\nMerci pour votre confiance et votre fidélité !\n"

  # Sujet en français
  subject="Votre facture d'énergie pour $month"
  bash ${cs_path}/commands/cs_send_email.sh "$email" "$subject" "$body" "$admin_email" "$bill_file"
done

exit 0
