# cluster-healthcheck

Author: Akshat Kalkhanda
Email: akshatkalkhanda@gmail.com

## Usage

Run this script to check cluster health:

chmod +x cluster_monitor.sh

./cluster_monitor.sh                    # terminal only
./cluster_monitor.sh --email            # email on issues only (your preference)
./cluster_monitor.sh --email --always-mail  # email every run
./cluster_monitor.sh --email --quiet    # cron-safe, email on alerts

# Cron — every 30 minutes
*/30 * * * * /opt/scripts/cluster_monitor.sh --email --quiet
Add any configured options as needed (e.g., logging, namespaces, or alert thresholds) based on your environment.