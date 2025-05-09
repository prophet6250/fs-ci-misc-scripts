#!/bin/bash
set -xe
set -o pipefail

echo "Test args: $0 $*"

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <linux_git_url> <qcow2_image> <fs_type:avacado_xfstests_config_file>"
    echo
    echo "Example:"
    echo "  $0 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \\"
    echo "     ubuntu20.04-cloudimg-ppc64el.qcow2 \\"
    echo "     ext4:ci.yaml"
    exit 1
fi

root_dir="/home/ci-user"
linux_dir="${PWD}/linux"
ci_scripts_dir="$root_dir/ci-scripts"

if [ ! -d ${ci_scripts_dir} ] || [ -z "$(ls -A ${ci_scripts_dir})" ]; then
    git clone --depth=1 https://github.com/OjaswinM/ci-scripts.git ${ci_scripts_dir}
fi

build_dir="$ci_scripts_dir/build"
kernel_output_dir="${build_dir}/output/latest-kernel"
defconfig="ppc64le_guest_defconfig"


# this is the toolchain used to build the kernel
build_make_cmd="make kernel@ppc64le@fedora SRC=${linux_dir} JFACTOR=$(nproc) DEFCONFIG=${defconfig}"

# boot into ubuntu 20.04 by default
image_name="${2:-ubuntu20.04-cloudimg-ppc64el.qcow2}"
disk_make_dir="$ci_scripts_dir/root-disks"
disk_make_cmd="make $image_name"

if [[ ! -d $linux_dir ]]; then
    # clone mainline by default
    git clone --depth=1 ${1:-https://web.git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git} linux
fi

# build phase
pushd $build_dir
$build_make_cmd
popd

# root disk download
pushd $disk_make_dir
./install-deps.sh
make cloud-init-user-data.img
$disk_make_cmd
popd

boot_script_dir=$ci_scripts_dir/scripts/boot
uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()).replace('-', '')[:12])")
test_output_dir="/tmp/output-$uuid"

mkdir -p $test_output_dir

# 3rd argument is of form "fs:config, this is because handling spaces was becoming an issue"
boot_script="${boot_script_dir}/qemu-pseries --accel kvm --cpu POWER8 --cloud-image ${image_name} --test-name avocado --pexpect-timeout 0 --test-output-dir $test_output_dir --test-args $4 --mem-size 8G"

# boot qemu
KBUILD_OUTPUT=${kernel_output_dir} ${boot_script}
echo Output $?

# # cleanup so no misconfiguration happens over time (will take more time each time the script is run)
# #rm -rf ${linux_dir}
# #rm -rf ${ci_scripts_dir}/build/output/*

# Only for debug, dont uncomment otherwise
# test_output_dir="/tmp/output-ff7c21ad2676"
# test_output_dir="/tmp/output-test"

# convert logs to format of dashboard
xfstests_scripts_dir="$root_dir/fs-ci-misc-scripts/xfstests-scripts"
avocado_convert_script="$xfstests_scripts_dir/convert.py"
xml_path="$test_output_dir/results/result.xml"
xfstests_results_path="$test_output_dir/results/."
logs_op_path="$test_output_dir/output-logs/."
json_op_path="$test_output_dir/dashboard_result.json"
log_prefix="/var/log/ci-dashboard"

fs="${3%%:*}" # everything before :
config="${3##*:}" # everything after :
testtype="avocado-xfstest-$fs"
subtype="${config//./-}" # replace . with -

python3 $xfstests_scripts_dir/convert.py $xml_path $xfstests_results_path $logs_op_path $log_prefix --output_json $json_op_path --type $testtype --subtype $subtype | tee $test_output_dir/.convert.log
run_id=$(cat $test_output_dir/.convert.log | tail -n 1 |  awk '{print $3}')

$xfstests_scripts_dir/push_logs.sh $run_id $logs_op_path $json_op_path
