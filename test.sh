#!/bin/bash

for i in $(sudo ls /var/lib/sonm/worker_keystore/); do
	WORKER_ADDRESS=0x$(sudo cat /var/lib/sonm/worker_keystore/$i | jq '.address' | tr -d '"')
	echo $WORKER_ADDRESS
done