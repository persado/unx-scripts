Purge script
---

This script connects to the localhost ActiveMQ admin interface and checks the size of the queue "DLQ.inbound". With some customisation it can monitor/check any other queue. It will purge the queue using the admin interface if it exceeds 50000 (0.5M) messages.

It should be installed in the ActiveMQ users' crontab with an entry similar to this one:


```
*/10 * * * * cd /home/activemq/purgeDLQ && ./purge.sh > purge.log 2> /dev/null
```
