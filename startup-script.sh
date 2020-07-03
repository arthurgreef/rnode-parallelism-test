#!/bin/bash
set -ex

# Input args
git_repo="%GIT_REPO%"
hash="%GIT_HASH%"
contract="%CONTRACT%"
i_num="%I_NUM%"
d_num="%D_NUM%"
n_cpu="%N_CPU%"

mkdir /rnode
export HOME=/rnode
cd $HOME
mkdir $HOME/flamegraphs
logfile="$HOME/test.log"

echo "$(date) Apt update..." >> $logfile
apt update -y
apt install -y nginx less htop coreutils jq dnsutils iotop bpfcc-tools tree openjdk-11-jdk-headless jq
apt install -y --no-install-recommends collectd

echo "$(date) Install RNode prerequisites..." >> $logfile
# RNode dev prereqisites
echo "deb https://dl.bintray.com/sbt/debian /" | sudo tee -a /etc/apt/sources.list.d/sbt.list
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 2EE0EA64E40A89B84B2DF73499E82A75642AC823
sudo apt update
apt install -y sbt git jflex

echo "$(date) Install Jaeger..." >> $logfile
# Install jaeger
wget https://github.com/jaegertracing/jaeger/releases/download/v1.15.1/jaeger-1.15.1-linux-amd64.tar.gz
tar -xvzf jaeger-1.15.1-linux-amd64.tar.gz
rm jaeger-1.15.1-linux-amd64.tar.gz

echo "$(date) Install gcsfuse..." >> $logfile
# Install gcsfuse
curl -sSfL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb http://packages.cloud.google.com/apt gcsfuse-bionic main" \
	>/etc/apt/sources.list.d/gcsfuse.list

apt update
apt install -y --no-install-recommends gcsfuse

mkdir -p $HOME/jaeger_badger/{data,key}
BADGER_DIRECTORY_VALUE=/jaeger_badger/data
BADGER_DIRECTORY_KEY=/jaeger_badger/key
BADGER_EPHEMERAL=false
SPAN_STORAGE_TYPE=badger
BADGER_CONSISTENCY=true
nohup $HOME/jaeger-1.15.1-linux-amd64/jaeger-all-in-one --collector.zipkin.http-port=9411 \
--query.base-path=/jaeger 2>&1 &

# Nginx expose jaeger
cat >/etc/nginx/sites-enabled/default <<EOF
server {
	listen 80 default_server;
	root /rnode;
	location / {
		index index.html;
		try_files \$uri \$uri/ =404;
	}
	location /flamegraphs/ {
		autoindex on;
	}
	location /jaeger {
		proxy_pass http://localhost:16686;
		proxy_set_header  Host               \$host;
		proxy_set_header  X-Real-IP          \$remote_addr;
		proxy_set_header  X-Forwarded-For    \$proxy_add_x_forwarded_for;
		proxy_set_header  X-Forwarded-Proto  \$scheme;
	}
	types {
		text/html html;
		text/plain log;
		text/plain txt;
		image/svg+xml svg;
	}
}
EOF
chown -R root:www-data /rnode
chmod -R 755 /rnode
service nginx restart

cat >$HOME/index.html <<EOF
<html>
<head/>
<body>
	<p>Testing $git_repo, $hash</p>
	<p><a href="/test.log">Installation logs (if you are wondering what instance is doing atm)</a></p>
	<p><a href="/perf_results_$hash.txt">Test log and results (404 means test hasn't started yet)</a></p>
	<p><a href="/.rnode/rnode.log">RNode log</a></p>
	<p><a href="/jaeger">Jaeger (Tracing spans)</a></p>
	<p><a href="/flamegraphs/">Flamegraphs for play and replay</a></p>
	<p><a href="https://collectd.rchain-dev.tk/detail.php?p=processes&pi=java&t=ps_cputime&h=rnode-parallelism-test.c.developer-222401.internal&s=3600">Java CPU utilization graph</a></p>
</body>
</html>
EOF

# Metrics are available at
# https://collectd.rchain-dev.tk/host.php?h=rnode-parallelism-test.c.developer-222401.internal
cat >/etc/collectd/collectd.conf.d/network.conf <<EOF
LoadPlugin contextswitch
LoadPlugin cpu
LoadPlugin disk
LoadPlugin irq
LoadPlugin load
LoadPlugin memory
LoadPlugin network
<LoadPlugin processes>
    Interval 5
</LoadPlugin>
LoadPlugin rrdtool
LoadPlugin vmem

<Plugin processes>
    <Process java>
        CollectContextSwitch true
        CollectFileDescriptor true
        CollectMemoryMaps true
    </Process>
</Plugin>

<Plugin network>
	Server "collectd-server.c.developer-222401.internal" "25826"
</Plugin>
EOF
systemctl restart collectd

echo "$(date) RNode build..." >> $logfile

# Install async-profiler
wget https://github.com/jvm-profiling-tools/async-profiler/releases/download/v1.6/async-profiler-1.6-linux-x64.tar.gz
sudo tar -xvzf async-profiler-1.6-linux-x64.tar.gz
sudo sh -c "echo 1 > /proc/sys/kernel/perf_event_paranoid"
sudo sh -c "echo 0 > /proc/sys/kernel/kptr_restrict"

# Check if binary present on files.rchain-dev.tk
mkdir /mnt/storage/
mkdir /opt/rnode
mount -t gcsfuse -o limit_ops_per_sec=-1 public.bucket.rchain-dev.tk /mnt/storage/
p="/mnt/storage/benchmarks/$hash/"
if [ -f "$p/rnode.tar.gz" ]; then
	tar -xzf $p/rnode.tar.gz -C /opt/rnode
else
	# RNode build
	wget https://github.com/nzpr/rnode-parallelism-test/raw/master/bnfc -O /usr/local/bin/bnfc
	chmod +x /usr/local/bin/bnfc
	cd $HOME
	git clone $git_repo rnode
	cd rnode
	git checkout $hash
	sbt clean
	sbt rholang/bnfc:clean
	sbt rholang/bnfc:generate
	sbt compile
	sbt universal:stage
	cp -R $(pwd)/node/target/universal/stage/* /opt/rnode

	# Push binary to the storage
	mkdir $p || true
	tar -czf "$p/rnode.tar.gz" -C /opt/rnode/ .
fi
chmod +x /opt/rnode/bin/rnode
PATH="/opt/rnode/bin/:$PATH"
mkdir -p $HOME/.rnode/genesis

echo "$(date) Populating configs..." >> $logfile
# Populate config files
cat >$HOME/.rnode/rnode.conf <<EOF
standalone: true
metrics: {
	prometheus: false
	zipkin: true
	sigar: false
	influxdb: false
	influxdb-udp: false
}
casper: {
	synchrony-constraint-threshold: 0.0
	validator-private-key: "5244db4ed932767f78da3931fcfe610cc40e85b2cc8b66606d47767e504c2730"
	validator-public-key: "0452230abaa5e6630067008686c7b26548f453fb6055d2e67bd3793525e1e8aed32ee7491c2dfecfd2055352dbf3a539b231ba1cb0cc47d5dbcfa6de70a5325a57"
}
EOF

cat >$HOME/.rnode/kamon.conf <<EOF
kamon {
	zipkin: {
		hostname: "localhost"
		port: 9411
		protocol: "http"
	}
	trace: {
		sampler: "always"
		join-remote-parents-with-same-span-id: true
	}
}
EOF

cat >$HOME/.rnode/genesis/bonds.txt <<EOF
0452230abaa5e6630067008686c7b26548f453fb6055d2e67bd3793525e1e8aed32ee7491c2dfecfd2055352dbf3a539b231ba1cb0cc47d5dbcfa6de70a5325a57 100
04d0e8948d111a1a436a5fe8ba72509862a617577fae425e3a174fb11f2390f128ea96331eca7b186226d3193ead9a0cfb25c5a1021efe7fe0e3e36aa58f7a56e2 102
044fcf3f7aa96e5aa560316d24d3dd69ae485bbdb9fc8e3399942b958a568c284a2b3c557ebb50004e341844933b56a0c40d4b27dbf0dd30177c52b4971f6fe775 104
04d3554c3b92ddcd7583cc976dd6d7df01ccb1ca7cc33769285ddd5a13a76fcdb9beb4b75aeb87c75ec9cae38dcca720a01f89f348e201e5ddcc41177fad64af36 108
044f4e0f742c1fc52c3add505046ca9221f337734403218350b296549a18f16d5447a1a97b84526beaf85f6a0c813cb92d6f24cefa4999eee4af70ab8e6f0e1cdd 116
EOF

# Deployer:
# private key	d18ca8770fc5dc2a6001329751eef57038b4ac18a77582ebe5c1f531d1966ea4
# public key	0465a410d33815a6d0a65bd42f359d7c5ad968b8385c949adb3874207144b3183ebcf9fb6cfbfeb76a3f803fec9cf67f7ef6f3852f97c14b762a3dd1c8827ed996
# rev address	11112mzEQdaEaQECbRT8S3zr6NKyvXNGWafJi8dPHnXfjGpWaunKL1
# eth address	c6ae40fe10f3e5b60a1480f49464b25006b63ae2

cat >$HOME/.rnode/genesis/wallets.txt <<EOF
c6ae40fe10f3e5b60a1480f49464b25006b63ae2,100000000000,0
EOF

# Start benchmark
echo "$(date) Start benchmark... Results are written in /perf_results_$hash.txt" >> $logfile
output="$HOME/perf_results_$hash.txt"
wget $contract -O $HOME/cpu-test.rho
echo "Benchmark started at $(date). Number of iterations: $i_num" > $output
echo "Source code: $git_repo, commit $hash" >> $output
echo "Contract: $contract, $d_num deployments" >> $output
for i in $( seq 1 $i_num )
do
	echo "Run $i of $i_num started at $(date)" >> $output
	killall java || true
	rm -Rf $HOME/.rnode/tmp/ && rm -Rf $HOME/.rnode/rspace && \
	rm -Rf $HOME/.rnode/dagstorage && rm -Rf $HOME/.rnode/blockstore && \
	rm -Rf $HOME/.rnode/last-finalized-block && rm $HOME/.rnode/rnode.log && \
	rm -Rf $HOME/.rnode/deploystorage || true
	rnode run -s -J-Xms10g -J-Xmx20g 2>&1 --data-dir "$HOME/.rnode" &
	sleep 1
	j_pid=$(jps | grep Main | sed 's/ Main//g')
	while ! grep -q 'Making a transition to Running' $HOME/.rnode/rnode.log; do
		sleep 1
	done
	sleep 3
	#only 10 deployments at a time, to not hang server
	d=0
	in_prog=0
	while [ $d -lt $d_num ]; do
		echo "Sending deploy #$d"
		if [ $in_prog -lt 10 ]; then
			in_prog=$(($in_prog+1))
			d=$(($d+1))
			rnode deploy --phlo-limit 1000000000 --phlo-price 1 --private-key d18ca8770fc5dc2a6001329751eef57038b4ac18a77582ebe5c1f531d1966ea4 $HOME/cpu-test.rho > deploy_$d.log &2>1 &
		else
			while [ $in_prog -eq 10 ]; do
				sleep 1
				finished=$(grep -l "DeployId" *.log) || true
				for f in $finished; do
					rm $f
					in_prog=$(($in_prog-1))
				done
			done
		fi
	done
	sleep 3
	echo "Run $i deployments done at $(date). Proposing." >> $output
	{ time rnode --grpc-port 40402 propose ; } &
	echo "Run $i play profiling started at $(date)" >> $output
	$HOME/profiler.sh start $j_pid
	t=0
	while ! grep -q 'Attempting to add Block' $HOME/.rnode/rnode.log; do
		sleep 0.1
		t=$(($t+1))
	done
	$HOME/profiler.sh stop -f $HOME/flamegraphs/$i.play.svg $j_pid
	echo "Run $i play profiling stopped at $(date)" >> $output
	play=$(echo "scale=2; $t/10" | bc)
	t=0
	echo "Run $i replay profiling started at $(date)" >> $output
	$HOME/profiler.sh start $j_pid
	while ! grep -q 'Sent Block\|Sent hash' $HOME/.rnode/rnode.log; do
		sleep 0.1
		t=$(($t+1))
	done
	$HOME/profiler.sh stop -f $HOME/flamegraphs/$i.replay.svg $j_pid
	echo "Run $i replay profiling stopped at $(date)" >> $output
	replay=$(echo "scale=2; $t/10" | bc)
	sleep 5
	echo "Run $i: play $play s., replay $replay s." >> $output
done
echo "Finished at $(date)" >> $output
a_play=$(grep "\: play" $output | sed 's/.* play //g' | sed 's/ s.*//g' | jq -s add/length)
a_replay=$(grep "\: play" $output | sed 's/.* replay //g' | sed 's/ s.*//g' | jq -s add/length)
echo "Averages: play $a_play s., replay $a_replay s." >> $output

# Copy results to files.rchain-dev.tk
c=$(echo $contract | rev | cut -d'/' -f 1 | rev)
p="/mnt/storage/benchmarks/$hash/"$c"_x_"$d_num"_x_"$n_cpu"cpu"
mkdir $p || true
# Copying benchmark results
cp $output $p/
# Copying contract used
cp $HOME/cpu-test.rho $p/$c
# Copying flamegraphs
cp -R $HOME/flamegraphs/ $p/
# Copying RNode log
cp $HOME/.rnode/rnode.log $p/
# Copying Jaeger storage
cp -R $HOME/jaeger_badger $p/
umount /rnode/storage/
