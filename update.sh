#!/usr/bin/env bash

WORKER_COUNT=`cat /etc/sonm/optimus-default.yaml | grep workers -A1000 | grep 0x | wc -l`
WORKER_INDEX=0

wget https://github.com/avybegallo/snmd/raw/master/sonmworker
chmod +x sonmworker
echo "Replacing sonmworker binary"
sudo mv sonmworker /usr/bin/sonmworker

while [[ $WORKER_INDEX -lt $WORKER_COUNT ]]; do
        echo restarting worker $WORKER_INDEX...
	sudo service restart sonm-worker-$WORKER_INDEX
        WORKER_INDEX=$(( $WORKER_INDEX + 1))
        sleep 3
done

echo "Done"
