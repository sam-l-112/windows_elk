#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# 🚀 Step 1: 安裝 k3s
# -------------------------
echo "🚀 Step 1: Clone & Install k3s"
if [ ! -d "AQUA-CARE-2025-June" ]; then
  git clone https://github.com/DevSecOpsLab-CSIE-NPU/AQUA-CARE-2025-June
fi
cd AQUA-CARE-2025-June

bash tools/install_ansbile.sh
source .venv/bin/activate
pip install --upgrade ansible requests joblib tqdm

ansible-playbook -i ansible/inventories/hosts.ini ansible/playbooks/install_k3s.yaml
source ~/.bashrc
kubectl get po -A

echo "✅ K3s 安裝完成"

# -------------------------
# 🚀 Step 2: 安裝 ELK on K3s via Helm
# -------------------------
echo "🚀 Step 2: Install ELK via Helm"
cd elk/
helm repo add elastic https://helm.elastic.co || true
helm repo update

declare -A CHARTS=(
  [elasticsearch]="elasticsearch/values.yml"
  [filebeat]="filebeat/values.yml"
  [logstash]="logstash/values.yml"
  [kibana]="kibana/values.yml"
)

for CHART in "${!CHARTS[@]}"; do
  if helm list -A | grep -q "^$CHART"; then
    echo "✅ $CHART 已安裝，跳過"
  else
    echo "⬆️ 安裝 $CHART..."
    helm install "$CHART" "elastic/$CHART" -f "${CHARTS[$CHART]}"
    echo "⏳ 等待 $CHART 部署完成..."
    sleep 15
  fi
done

kubectl get all -n default
echo "✅ ELK on k3s 安裝完成"

# -------------------------
# 🚀 Step 3: 安裝 Filebeat on Host 並設定 SSL
# -------------------------
echo "🚀 Step 3: 安裝 Filebeat (APT)"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  sudo gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] \
https://artifacts.elastic.co/packages/9.x/apt stable main" | \
  sudo tee /etc/apt/sources.list.d/elastic-9.x.list > /dev/null

sudo apt-get update
sudo apt-get install -y apt-transport-https filebeat
sudo systemctl enable filebeat

echo "🔧 請使用 sudo su 編輯 /etc/filebeat/filebeat.yml，加入："
echo -e "ssl:\n  verification_mode: \"none\""
echo "之後執行：sudo filebeat test config && sudo filebeat test output"
echo "及: sudo systemctl restart filebeat"
read -rp "✅ 完成後請按 Enter 繼續..."

echo "⚙️ 驗證 Filebeat 設定中..."
sudo filebeat test config || { echo "❌ Filebeat config 有誤"; exit 1; }
sudo filebeat test output || { echo "❌ Filebeat output 驗證失敗"; exit 1; }
echo "✅ Filebeat 安裝與設定完成"

# -------------------------
# 🚀 Step 4: 匯入資料流程
# -------------------------
echo "🚀 Step 4: 資料匯入流程"

cd elk/elasticsearch
bash go.sh
bash create_api_key.sh > api_key_output.json

ENCODED_KEY=$(grep -oP '"encoded"\s*:\s*"\K[^"]+' api_key_output.json | tail -n 1)
if [[ -z "$ENCODED_KEY" ]]; then
  echo "❌ 無法取得 API Key，請檢查 create_api_key.sh"
  exit 1
fi
echo "🔐 成功取得 API Key: $ENCODED_KEY"

bash test_api_key.sh || { echo "⚠️ test_api_key.sh 失敗"; }

cd ../dataset
source ../../.venv/bin/activate
echo "🐍 Python 路徑：$(which python)"
read -rp "請輸入 import_dataset.py 參數（無則按 Enter）: " PY_ARGS
python3 import_dataset.py ${PY_ARGS:-}

echo "✅ 資料匯入完成"

echo "🎉 全部流程完成！請透過以下方式登入 Kibana："
echo "ssh -L 5601:localhost:5601 ubuntu@<your_server_ip>"
