Purge script
---

This script connects to the localhost ActiveMQ admin interface and checks the size of the queue "DLQ.inbound". With some customisation it can monitor/check any other queue. It will purge the queue using the admin interface if it exceeds 50000 (0.5M) messages.

It should be installed in the ActiveMQ users' crontab with an entry similar to this one for default settings:

```
*/10 * * * * cd /home/activemq/purgeDLQ && ./purge.sh > purge.log 2> /dev/null
```

for different queues, you need additional entries like the one below. It will purge if queue mcs.outbound.smsmt.claro_com_br.DLQ goes over 20000 messages.

```
*/10 * * * * cd /home/activemq/purgeDLQ && ./purge.sh mcs.outbound.smsmt.claro_com_br.DLQ 20000 > purge.log 2> /dev/null
```


