#!/usr/bin/env bash
set -euo pipefail

# === Phase 1: Clone & Setup Ansible/k3s ===
echo "🚀 Step 1: Clone & Install k3s"
if [ ! -d "AQUA-CARE-2025-June" ]; then
  git clone https://github.com/DevSecOpsLab-CSIE-NPU/AQUA-CARE-2025-June
fi
cd AQUA-CARE-2025-June

bash tools/install_ansbile.sh
source .venv/bin/activate
pip install --upgrade ansible requests joblib tqdm

ansible-playbook -i ansible/inventories/hosts.ini ansible/playbooks/install_k3s.yaml

# === Phase 2: Configure Kubeconfig ===
echo "🛠 Configure kubeconfig"
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=$HOME/.kube/config
if ! grep -q "KUBECONFIG" ~/.bashrc; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
fi
source ~/.bashrc

kubectl get po -A

# === Phase 3: Deploy ELK via Helm ===
echo "🚀 Step 2: Install ELK via Helm"
cd elk/
helm repo add elastic https://helm.elastic.co || true
helm repo update

declare -A CHARTS
CHARTS=( 
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
    sleep 10
  fi
done

kubectl get all -n default

# === Phase 4: Install Filebeat on Host ===
echo "📥 Step 3: 安裝 Filebeat (APT)"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  sudo gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-9.x.list > /dev/null

sudo apt-get update
sudo apt-get install -y apt-transport-https filebeat
sudo systemctl enable filebeat

# === Phase 5: Configure Filebeat SSL Skip ===
echo "🛠 手動設定 Filebeat：需要 sudo su 權限編輯 /etc/filebeat/filebeat.yml"
echo "請加入："
echo -e "ssl:\n  verification_mode: \"none\""
echo "然後執行："
echo "sudo filebeat test config && sudo filebeat test output"
echo "sudo systemctl restart filebeat"
echo "🔐 請輸入 'sudo su' 取得 root 權限後再操作以上設定"
read -rp "✅ 完成後請按 Enter 繼續..."

# === Phase 6: Import Sample Data & Create API Key ===
echo "🔑 Step 4: 匯入資料 & 建立 API Key"
cd elasticsearch
bash go.sh
bash create_api_key.sh > api_key_output.json

ENCODED_KEY=$(grep -oP '"encoded"\s*:\s*"\K[^"]+' api_key_output.json | tail -n 1)
if [[ -z "$ENCODED_KEY" ]]; then
  echo "❌ 無法取得 API Key，請檢查 create_api_key.sh 輸出"
  exit 1
fi

echo "🔐 Extracted API Key: $ENCODED_KEY"
bash test_api_key.sh || echo "⚠️ test_api_key.sh 失敗"

# === Phase 7: Import Dataset ===
echo "🐍 Step 5: 匯入 Dataset"
cd ../dataset
source ../../.venv/bin/activate

echo "Python path: $(which python)"
read -rp "請輸入 import_dataset.py 參數（無參數直接 Enter）: " PY_ARGS
python3 import_dataset.py $PY_ARGS

echo "✅ 完成！Kibana 介面：http://localhost:5601 （請自行透過 SSH tunnel 登入）"
