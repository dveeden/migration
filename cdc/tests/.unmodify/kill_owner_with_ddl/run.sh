#!/bin/bash

set -eu

CUR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $CUR/../_utils/test_prepare
WORK_DIR=$OUT_DIR/$TEST_NAME
CDC_BINARY=tikv-cdc.test
SINK_TYPE=$1

MAX_RETRIES=10
UP_PD=http://$UP_PD_HOST_1:$UP_PD_PORT_1
DOWN_PD=http://$DOWN_PD_HOST:$DOWN_PD_PORT

function check_capture_count() {
	pd=$1
	expected=$2
	count=$(tikv-cdc cli capture list --pd=$pd 2>&1 | jq '.|length')
	if [[ ! "$count" -eq "$expected" ]]; then
		echo "count: $count expected: $expected"
		exit 1
	fi
}

function kill_cdc_and_restart() {
	pd_addr=$1
	work_dir=$2
	cdc_binary=$3
	MAX_RETRIES=10
	status=$(curl -s http://127.0.0.1:8600/status)
	cdc_pid=$(echo "$status" | jq '.pid')

	kill $cdc_pid
	ensure $MAX_RETRIES check_capture_count $pd_addr 0
	run_cdc_server --workdir $work_dir --binary $cdc_binary --addr "127.0.0.1:8600" --pd $pd_addr
	ensure $MAX_RETRIES check_capture_count $pd_addr 1
}

export -f check_capture_count
export -f kill_cdc_and_restart

function run() {

	rm -rf $WORK_DIR && mkdir -p $WORK_DIR
	start_tidb_cluster --workdir $WORK_DIR
	cd $WORK_DIR

	case $SINK_TYPE in
	tikv) SINK_URI="tikv://${DOWN_PD_HOST}:${DOWN_PD_PORT}" ;;
	*) SINK_URI="" ;;
	esac

	run_cdc_server --workdir $WORK_DIR --binary $CDC_BINARY --addr "127.0.0.1:8600" --pd $UP_PD
	tikv-cdc cli changefeed create --pd=$UP_PD --sink-uri="$SINK_URI"
	sleep 10

	export GO_FAILPOINTS='github.com/tikv/migration/cdc/cdc/capture/ownerFlushIntervalInject=return(10)'
	kill_cdc_and_restart $UP_PD $WORK_DIR $CDC_BINARY

	rawkv_op $UP_PD put 10000

	for i in $(seq 1 3); do
		kill_cdc_and_restart $UP_PD $WORK_DIR $CDC_BINARY
		sleep 8
	done

	export GO_FAILPOINTS=''
	kill_cdc_and_restart $UP_PD $WORK_DIR $CDC_BINARY

	check_sync_diff $WORK_DIR $UP_PD $DOWN_PD
	rawkv_op $UP_PD delete 10000
	check_sync_diff $WORK_DIR $UP_PD $DOWN_PD

	cleanup_process $CDC_BINARY
}

trap stop_tidb_cluster EXIT
run $*
check_logs $WORK_DIR
echo "[$(date)] <<<<<< run test case $TEST_NAME success! >>>>>>"
