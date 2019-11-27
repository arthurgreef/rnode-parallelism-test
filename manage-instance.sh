#!/bin/zsh

name=rnode-parallelism-test
export CLOUDSDK_COMPUTE_ZONE=us-east1-d

create_args=(
        --machine-type=n1-highcpu-$3
		--min-cpu-platform='Intel Skylake'
		--image-project=ubuntu-os-cloud
		--image-family=ubuntu-1910
		--metadata-from-file=startup-script="startup-script.run"
		--tags=collectd-out,http
		--service-account=public-files-writer@developer-222401.iam.gserviceaccount.com
		--scopes=https://www.googleapis.com/auth/cloud-platform
)
gcloud compute instances delete $name --quiet || true
gcloud compute instances create $name $create_args 2>&1 > ./.gcloud.log

IP=$(grep RUNNING .gcloud.log | cut -d ' ' -f 22)
echo "Installing instance... Visit http://$IP after several minutes to follow the progress. \
Do not close this shell, it will be closed automatically when benchmark is finished."

while ! curl -s $IP/perf_results_$1.txt | grep -q 'Finished'; do
	sleep 1
done
mkdir -p results/$1
wget --quiet -P results/$1 $IP/perf_results_$1.txt 
echo "Benchmark finished, results are in $IP/perf_results_$1.txt."
if $2; then
	echo "Shutting down instance $name"
	echo "Results saved into results/perf_results_$1.txt"
	gcloud compute instances delete $name --quiet || true
	exit 
fi 
echo "Tracing spans are available at http://$IP/jaeger"
echo "WARNING!!! Instance is still running and have to be payed for. Run gcloud compute instances delete $name asap."