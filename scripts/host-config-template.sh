set -xeuo pipefail

S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
MODEL_WHL="__MODEL_WHL__"
SESSIONS_WHL="__SESSIONS_WHL__"
AGENT_WHL="__AGENT_WHL__"
DEADLINE_WHL="__DEADLINE_WHL__"

echo "Running Host Configuration script to install Rust-backed openjd libraries."
ls /var/lib/deadline
if [ -f /var/lib/deadline/rebooted ]; then
    echo "Host already rebooted, ready to start."
    exit 0
fi
echo "Host has not been rebooted."

source /opt/deadline/worker/bin/activate

for WHL in $MODEL_WHL $SESSIONS_WHL $AGENT_WHL $DEADLINE_WHL; do
    echo "Downloading $WHL from s3://$S3_BUCKET/$S3_PREFIX/$WHL"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$WHL" /tmp/
done

pip install /tmp/$MODEL_WHL --force-reinstall --no-deps
pip install /tmp/$SESSIONS_WHL --force-reinstall --no-deps
pip install /tmp/$AGENT_WHL --force-reinstall --no-deps
pip install /tmp/$DEADLINE_WHL --force-reinstall --no-deps

chmod -R go+rx /opt/deadline/worker

echo "Installed packages:"
pip list | grep -i "openjd\|deadline"

touch /var/lib/deadline/rebooted
chmod 660 /var/lib/deadline/rebooted
echo "Marker file created, rebooting worker host."
sudo reboot now
sleep 60
exit 1
