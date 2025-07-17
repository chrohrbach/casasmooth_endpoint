#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.1.2
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
  
  # Calculate totals from new CSV format: timestamp,txid,entity_id,entity_name,ordered_kwh,consumed_kwh,start_time,end_time,duration_hours,end_reason
  total_ordered_kwh=$(echo "$transactions" | awk -F',' '{sum+=$5} END {printf "%.2f", sum}')
  total_consumed_kwh=$(echo "$transactions" | awk -F',' '{sum+=$6} END {printf "%.2f", sum}')
  total_duration=$(echo "$transactions" | awk -F',' '{sum+=$9} END {printf "%.2f", sum}')
  
  # Calculate estimated cost (we'll need to implement cost calculation since it's not in the CSV anymore)
  # For now, using a simple rate - this should be enhanced with actual cost calculation
  grid_rate="0.35"  # CHF per kWh - should be configurable
  estimated_cost=$(echo "$total_consumed_kwh * $grid_rate" | bc -l | xargs printf "%.2f")

  # Préparer le corps du mail en français
  body="Bonjour,\n\nVoici le récapitulatif de votre consommation d'énergie pour le mois de $month :\n\n"
  body+="Date, Transaction, Appareil, kWh Commandé, kWh Consommé, Durée (h), Motif d'arrêt\n"
  body+="================================================================================\n"
  
  while IFS=',' read -r timestamp txid entity_id entity_name ordered_kwh consumed_kwh start_time end_time duration_hours end_reason; do
    # Clean up quoted fields
    entity_name=$(echo "$entity_name" | tr -d '"')
    end_reason=$(echo "$end_reason" | tr -d '"')
    date_only="${timestamp%%T*}"
    body+="${date_only}, ${txid:0:8}..., $entity_name, $ordered_kwh, $consumed_kwh, $duration_hours, $end_reason\n"
  done <<< "$transactions"
  
  body+="\n================================================================================\n"
  body+="RÉSUMÉ DU MOIS:\n"
  body+="Énergie totale commandée: $total_ordered_kwh kWh\n"
  body+="Énergie totale consommée: $total_consumed_kwh kWh\n"
  body+="Durée totale des sessions: $total_duration heures\n"
  body+="Coût estimé (tarif réseau): CHF $estimated_cost\n\n"
  
  if (( $(echo "$total_consumed_kwh > $total_ordered_kwh" | bc -l) )); then
    excess=$(echo "$total_consumed_kwh - $total_ordered_kwh" | bc -l | xargs printf "%.2f")
    body+="⚠️  ATTENTION: Consommation supérieure de $excess kWh à la quantité commandée\n\n"
  fi
  
  body+="Merci pour votre confiance et votre fidélité !\n\n"
  body+="Note: Le coût final sera calculé selon les tarifs en vigueur et la provenance de l'énergie (réseau/solaire)."

  # Sujet en français avec détails de consommation
  subject="Facture d'énergie $month - $total_consumed_kwh kWh consommé - CHF $estimated_cost"
  bash ${cs_path}/commands/cs_send_email.sh "$email" "$subject" "$body" "$admin_email" "$bill_file"
done

exit 0
