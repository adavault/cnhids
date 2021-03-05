# cnhids
cnhids is a Host Intrusion Detection System for cardano node based on https://github.com/ossec/ossec-hids:

- cnHids aims to provide an easy way to monitor and analyse OSSEC data by feeding into Prometheus and Grafana to make a simple SIEM.
- Some common use cases have been added to the dashboard as panels (more are expected to be developed).
- Some customisation of OSSEC agents provides better monitoring for the GuildOps cnTools standard directory structure.
- To install download and run setup_mon.sh (run without args to see options)

Run without args to see options. Some customisations via user variables at the top of the script.

To install cnHids: ./setup_mon.sh -H

To install remote agents: ./setup_mon.sh -A

Also support installation of base performance monitoring (drop in for GuildOps setup_mon.sh script)

To install remote performance monitoring for 3 nodes (that allow access to cardano node and node exporter ports):<br>
./setup_mon.sh -M -i cnode1.your-domain,cnode2.your-domain,cnode3.your-domain

To install node exporter on cardano nodes for remote monitoring: ./setup_mon.sh -N

Tested on Ubuntu 20.04 LTS. May work on other distros and architectures, try and feedback.

Details available here:<br>
https://adavault.com/index.php/2021/01/28/cardano-node-security-monitoring/

Improvements planned:

- preserve prometheus data when installing/upgrading
- more HIDS use cases
- remove/reduce manual interaction to install OSSEC elements
- customise grafana look and feel (partly completed- allows custom logos, favicons etc)

