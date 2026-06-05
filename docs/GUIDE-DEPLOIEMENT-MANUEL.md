# Guide de Déploiement Manuel AWS (CLI) - E-Commerce Microservices
**Auteur :** Yara Mahi Mohamed
**Stack :** React 18 + NGINX | Node.js 20 microservices | RDS MySQL 8.4 | **EKS Auto Mode** + Helm
**Objectif :** Déployer en ligne de commande (`aws`, `kubectl`, `helm`) - le miroir CLI du [Guide Console AWS](./GUIDE-CONSOLE-AWS.md)

> 📖 **Voir aussi** : [Architecture détaillée](./ARCHITECTURE.md) · [Guide Console AWS (interface web)](./GUIDE-CONSOLE-AWS.md) · [Terraform](../terraform/)
>
> ℹ️ Ce guide reproduit **exactement** l'architecture du guide console : base **RDS MySQL 8.4** (`db.t4g.micro`, Single-AZ), cluster **EKS Auto Mode** (pas de Node Group), microservices sur **GHCR public**, **ECR uniquement pour le frontend**, DNS sur **Cloudflare**, CloudFront **optionnel**.

---

## Sommaire

1. [Prérequis & Configuration AWS CLI](#1-prérequis--configuration-aws-cli)
2. [VPC & Réseau](#2-vpc--réseau)
3. [Security Groups](#3-security-groups)
4. [RDS MySQL 8.4](#4-rds-mysql-84)
5. [Secrets Manager](#5-secrets-manager)
6. [ECR - Registry frontend](#6-ecr--registry-frontend)
7. [EKS Auto Mode - Cluster Kubernetes](#7-eks-auto-mode--cluster-kubernetes)
8. [Déploiement Helm des microservices (GHCR)](#8-déploiement-helm-des-microservices-ghcr)
9. [ALB Public & Routing](#9-alb-public--routing)
10. [Frontend Option A - EC2 (NGINX natif)](#10-frontend-option-a--ec2-nginx-natif)
11. [Frontend Option B - Elastic Beanstalk](#11-frontend-option-b--elastic-beanstalk)
12. [Frontend Option C - ECS Fargate](#12-frontend-option-c--ecs-fargate)
13. [CloudFront + DNS (optionnel)](#13-cloudfront--dns-optionnel)
14. [Vérification End-to-End](#14-vérification-end-to-end)

---

## Variables globales à définir

Avant de commencer, exportez ces variables. Elles sont réutilisées dans toutes les commandes.

```bash
export AWS_REGION="eu-west-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT="ecommerce"
export ENV="prod"

# Réseau
export VPC_CIDR="10.0.0.0/16"

# Base de données
export DB_NAME="ecommerce_db"
export DB_USER="devops_user"
export DB_PASSWORD="CHANGEZ_MOI_db_password_32chars"   # ⚠️ Changez ceci

# JWT (même secret pour les 4 microservices)
export JWT_SECRET="CHANGEZ_MOI_jwt_secret_min_32_chars"  # ⚠️ Changez ceci

echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"
```

---

## 1. Prérequis & Configuration AWS CLI

### Outils requis

```bash
aws --version          # >= 2.15 (support EKS Auto Mode)
kubectl version        # >= 1.30
helm version           # >= 3.x
docker --version       # >= 20.10
jq --version           # parsing JSON
```

### Installation rapide (Ubuntu/Debian)

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Configurer AWS CLI

```bash
aws configure          # Access Key, Secret Key, region=eu-west-1, output=json
aws sts get-caller-identity
```

> ℹ️ **EKS Auto Mode ne nécessite plus `eksctl`** : tout se fait avec `aws eks create-cluster` (compute/storage/networking gérés par AWS).

---

## 2. VPC & Réseau

Architecture réelle : 3 AZ, subnets en **/20**, 3 niveaux (public / privé EKS / DB). cf. [ARCHITECTURE.md $4](./ARCHITECTURE.md).

### Créer le VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc},{Key=Env,Value=$ENV}]" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support  "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"
echo "VPC : $VPC_ID"
```

### Internet Gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
```

### Subnets publics (3 AZ - /20) - ALB public, NAT, frontend

```bash
declare -A PUB_CIDR=( [a]=10.0.0.0/20 [b]=10.0.16.0/20 [c]=10.0.32.0/20 )
declare -A SUBNET_PUB
for az in a b c; do
  SUBNET_PUB[$az]=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block ${PUB_CIDR[$az]} \
    --availability-zone "${AWS_REGION}${az}" \
    --tag-specifications "ResourceType=subnet,Tags=[\
{Key=Name,Value=$PROJECT-subnet-public-$az},\
{Key=kubernetes.io/role/elb,Value=1},\
{Key=kubernetes.io/cluster/$PROJECT-cluster,Value=shared}]" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 modify-subnet-attribute --subnet-id ${SUBNET_PUB[$az]} --map-public-ip-on-launch
done
echo "Publics : ${SUBNET_PUB[a]} ${SUBNET_PUB[b]} ${SUBNET_PUB[c]}"
```

### Subnets privés EKS (3 AZ - /20) - nœuds Auto Mode, pods, ALB interne

```bash
declare -A PRIV_CIDR=( [a]=10.0.128.0/20 [b]=10.0.144.0/20 [c]=10.0.160.0/20 )
declare -A SUBNET_PRIV
for az in a b c; do
  SUBNET_PRIV[$az]=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block ${PRIV_CIDR[$az]} \
    --availability-zone "${AWS_REGION}${az}" \
    --tag-specifications "ResourceType=subnet,Tags=[\
{Key=Name,Value=$PROJECT-subnet-private-$az},\
{Key=kubernetes.io/role/internal-elb,Value=1},\
{Key=kubernetes.io/cluster/$PROJECT-cluster,Value=shared}]" \
    --query 'Subnet.SubnetId' --output text)
done
echo "Privés : ${SUBNET_PRIV[a]} ${SUBNET_PRIV[b]} ${SUBNET_PRIV[c]}"
```

> ⚠️ Le tag `kubernetes.io/cluster/$PROJECT-cluster=shared` sur les subnets privés est **obligatoire** : sans lui, l'AWS Load Balancer Controller ne découvre pas les subnets et l'ALB interne EKS ne se crée pas.

### Subnets base de données (3 AZ - /20) - isolés

```bash
declare -A DB_CIDR=( [a]=10.0.48.0/20 [b]=10.0.64.0/20 [c]=10.0.80.0/20 )
declare -A SUBNET_DB
for az in a b c; do
  SUBNET_DB[$az]=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID --cidr-block ${DB_CIDR[$az]} \
    --availability-zone "${AWS_REGION}${az}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-db-$az}]" \
    --query 'Subnet.SubnetId' --output text)
done
echo "DB : ${SUBNET_DB[a]} ${SUBNET_DB[b]} ${SUBNET_DB[c]}"
```

### NAT Gateway (sortie internet des nœuds EKS - une par AZ a/b)

```bash
EIP_A=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
EIP_B=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)

NAT_A=$(aws ec2 create-nat-gateway --subnet-id ${SUBNET_PUB[a]} --allocation-id $EIP_A \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-a}]" \
  --query 'NatGateway.NatGatewayId' --output text)
NAT_B=$(aws ec2 create-nat-gateway --subnet-id ${SUBNET_PUB[b]} --allocation-id $EIP_B \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-b}]" \
  --query 'NatGateway.NatGatewayId' --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_B
echo "NAT : $NAT_A | $NAT_B"
```

> 💡 En dev/portfolio, **une seule NAT Gateway suffit** (supprimer la redondance AZ pour économiser ~$33/mois).

### Tables de routage

```bash
# Publique → IGW (les 3 subnets publics)
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-pub}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
for az in a b c; do aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id ${SUBNET_PUB[$az]}; done

# Privées → NAT (a et b ; le subnet 'c' route via la NAT de l'AZ a)
RT_PRIV_A=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-priv-a}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRIV_A --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_A

RT_PRIV_B=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-priv-b}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRIV_B --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_B

# priv + db a/c → RT_PRIV_A ; priv + db b → RT_PRIV_B
for s in ${SUBNET_PRIV[a]} ${SUBNET_PRIV[c]} ${SUBNET_DB[a]} ${SUBNET_DB[c]}; do
  aws ec2 associate-route-table --route-table-id $RT_PRIV_A --subnet-id $s; done
for s in ${SUBNET_PRIV[b]} ${SUBNET_DB[b]}; do
  aws ec2 associate-route-table --route-table-id $RT_PRIV_B --subnet-id $s; done

echo "✅ Réseau complet"
```

---

## 3. Security Groups

**3 SG créés manuellement** (alb, frontend, rds). Les SG des nœuds EKS et de l'ALB interne sont **créés automatiquement** par EKS Auto Mode et le LB Controller (voir $7.6).

```bash
# SG ALB public
SG_ALB=$(aws ec2 create-security-group --group-name "$PROJECT-sg-alb" \
  --description "ALB public - HTTP/HTTPS depuis internet" --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-alb}]" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 443 --cidr 0.0.0.0/0

# SG Frontend (EC2 / Beanstalk / ECS) - :80 depuis l'ALB uniquement
SG_FRONTEND=$(aws ec2 create-security-group --group-name "$PROJECT-sg-frontend" \
  --description "Frontend - trafic depuis ALB uniquement" --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-frontend}]" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_FRONTEND --protocol tcp --port 80 --source-group $SG_ALB

# SG RDS - la règle :3306 ← nœuds EKS est ajoutée en $7.6 (après création du cluster)
SG_RDS=$(aws ec2 create-security-group --group-name "$PROJECT-sg-rds" \
  --description "RDS MySQL - acces depuis EKS uniquement" --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-rds}]" \
  --query 'GroupId' --output text)

echo "SG ALB:$SG_ALB | Frontend:$SG_FRONTEND | RDS:$SG_RDS"
```

> ✅ **Aucun port SSH (22)** n'est ouvert - l'accès aux instances se fait via **AWS Systems Manager Session Manager**.

---

## 4. RDS MySQL 8.4

Configuration réelle : **MySQL 8.4.8**, `db.t4g.micro` (ARM Graviton, Free Tier), **Single-AZ**, gp2, chiffré. MySQL 8.4 est compatible MariaDB 10.11 - schéma et drivers `mysql2` inchangés.

### Subnet group RDS

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$PROJECT-db-subnet-group" \
  --db-subnet-group-description "Subnets RDS MySQL $PROJECT" \
  --subnet-ids ${SUBNET_DB[a]} ${SUBNET_DB[b]} ${SUBNET_DB[c]} \
  --tags Key=Name,Value=$PROJECT-db-subnet-group
```

### Instance MySQL 8.4 (Single-AZ)

```bash
aws rds create-db-instance \
  --db-instance-identifier "$PROJECT-mysql" \
  --db-instance-class "db.t4g.micro" \
  --engine mysql \
  --engine-version "8.4.8" \
  --master-username $DB_USER \
  --master-user-password $DB_PASSWORD \
  --db-name $DB_NAME \
  --db-subnet-group-name "$PROJECT-db-subnet-group" \
  --vpc-security-group-ids $SG_RDS \
  --allocated-storage 20 \
  --storage-type gp2 \
  --storage-encrypted \
  --backup-retention-period 7 \
  --no-multi-az \
  --no-publicly-accessible \
  --no-deletion-protection \
  --tags Key=Name,Value=$PROJECT-mysql Key=Env,Value=$ENV

echo "Attente instance MySQL (~5-10min)..."
aws rds wait db-instance-available --db-instance-identifier "$PROJECT-mysql"

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$PROJECT-mysql" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
export DB_ENDPOINT
echo "✅ RDS endpoint : $DB_ENDPOINT"
```

### Importer le schéma

L'instance n'étant pas publique, importez depuis un **EC2 bastion** dans un subnet public (SG `ecommerce-sg-frontend`) ou via SSM. Avec SSL :

```bash
# Sur le bastion :
sudo dnf install -y mariadb105
curl https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o global-bundle.pem
mysql -h $DB_ENDPOINT -P 3306 -u $DB_USER -p \
  --ssl-ca=global-bundle.pem $DB_NAME < ecommerce_db.sql
echo "✅ Schéma importé"
```

> ℹ️ Arrêtez (ne supprimez pas) le bastion après l'import.

---

## 5. Secrets Manager

Deux secrets, aux clés attendues par les microservices (`DB_USER`/`DB_PASSWORD` et `JWT_SECRET`).

```bash
aws secretsmanager create-secret \
  --name "$PROJECT/db/credentials" \
  --description "Credentials RDS MySQL ecommerce" \
  --secret-string "{\"DB_USER\":\"$DB_USER\",\"DB_PASSWORD\":\"$DB_PASSWORD\"}"

aws secretsmanager create-secret \
  --name "$PROJECT/jwt/secret" \
  --description "JWT secret partage par les microservices" \
  --secret-string "{\"JWT_SECRET\":\"$JWT_SECRET\"}"

echo "✅ Secrets créés"
```

> 💡 Consommation : injectés au déploiement Helm (`--set`) côté EKS, ou via User Data / variables d'env / Task Definition côté frontend. Une intégration **Secrets Store CSI Driver + IRSA** (ASCP) est possible en option.

---

## 6. ECR - Registry frontend

**Seul le frontend** est sur ECR. Les 4 microservices restent sur **GHCR public** (`ghcr.io/yaraportfolio/*`) - aucun repo ECR ni credential requis pour eux.

```bash
aws ecr create-repository \
  --repository-name "$PROJECT/frontend" \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256 \
  --tags Key=Name,Value=$PROJECT-frontend Key=Env,Value=$ENV

# Lifecycle : garder les 10 dernières images
aws ecr put-lifecycle-policy --repository-name "$PROJECT/frontend" \
  --lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"Garder 10 images",
    "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},
    "action":{"type":"expire"}}]}'

echo "✅ ECR $PROJECT/frontend prêt"
```

> ℹ️ L'image frontend est buildée et poussée dans les sections **11** (Beanstalk) et **12** (ECS). L'**Option A (EC2)** ne l'utilise pas (build natif sur la VM).

---

## 7. EKS Auto Mode - Cluster Kubernetes

EKS **Auto Mode** : AWS gère le control plane **et** les nœuds (provisioning, scaling, patching). **Pas de Node Group, pas de Cluster Autoscaler.**

### 7.1 Rôles IAM (cluster + nœuds Auto Mode)

```bash
# --- Rôle du cluster ---
cat > /tmp/cluster-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"eks.amazonaws.com"},
 "Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF
aws iam create-role --role-name "$PROJECT-eks-cluster-role" \
  --assume-role-policy-document file:///tmp/cluster-trust.json
for P in AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicy \
         AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy; do
  aws iam attach-role-policy --role-name "$PROJECT-eks-cluster-role" \
    --policy-arn arn:aws:iam::aws:policy/$P
done

# --- Rôle des nœuds ---
cat > /tmp/node-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name "$PROJECT-eks-node-role" \
  --assume-role-policy-document file:///tmp/node-trust.json
for P in AmazonEKSWorkerNodeMinimalPolicy AmazonEC2ContainerRegistryPullOnly; do
  aws iam attach-role-policy --role-name "$PROJECT-eks-node-role" \
    --policy-arn arn:aws:iam::aws:policy/$P
done

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name "$PROJECT-eks-cluster-role" --query 'Role.Arn' --output text)
NODE_ROLE_ARN=$(aws iam get-role --role-name "$PROJECT-eks-node-role" --query 'Role.Arn' --output text)
```

### 7.2 Créer le cluster Auto Mode

```bash
aws eks create-cluster \
  --name "$PROJECT-cluster" \
  --kubernetes-version "1.31" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config "subnetIds=${SUBNET_PRIV[a]},${SUBNET_PRIV[b]},${SUBNET_PRIV[c]},endpointPublicAccess=true,endpointPrivateAccess=true" \
  --access-config authenticationMode=API \
  --compute-config "enabled=true,nodePools=general-purpose,nodePools=system,nodeRoleArn=$NODE_ROLE_ARN" \
  --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":false}}' \
  --storage-config '{"blockStorage":{"enabled":true}}' \
  --bootstrap-self-managed-addons false

echo "Attente cluster ACTIVE (~12min)..."
aws eks wait cluster-active --name "$PROJECT-cluster"
```

> ℹ️ `elasticLoadBalancing.enabled=false` : on utilise le **AWS Load Balancer Controller standalone** ($7.5) pour l'ALB interne, comme dans le guide console.

### 7.3 Configurer kubectl

```bash
aws eks update-kubeconfig --region $AWS_REGION --name "$PROJECT-cluster"
kubectl get nodes    # nœuds Auto Mode Ready après quelques minutes (selon la charge)
```

### 7.4 Add-ons (Metrics Server + ASCP)

```bash
# Metrics Server (requis pour le HPA)
aws eks create-addon --cluster-name "$PROJECT-cluster" --addon-name metrics-server

# AWS Secrets and Configuration Provider (optionnel - pour Secrets Manager via CSI/IRSA)
aws eks create-addon --cluster-name "$PROJECT-cluster" \
  --addon-name aws-secrets-store-csi-driver-provider
```

> ⚠️ **Ne PAS installer `aws-ebs-csi-driver`** : incompatible avec EKS Auto Mode (le block storage est déjà géré par Auto Mode via `storage-config`).

### 7.5 Enregistrer l'OIDC Provider + installer le AWS Load Balancer Controller

```bash
# OIDC provider (IRSA)
OIDC_URL=$(aws eks describe-cluster --name "$PROJECT-cluster" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_HOST=${OIDC_URL#https://}
THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.$AWS_REGION.amazonaws.com \
  -connect oidc.eks.$AWS_REGION.amazonaws.com:443 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout | cut -d= -f2 | tr -d ':')
aws iam create-open-id-connect-provider --url "$OIDC_URL" \
  --client-id-list sts.amazonaws.com --thumbprint-list "$THUMBPRINT"

# Policy IAM du LBC
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Rôle IRSA pour le ServiceAccount kube-system/aws-load-balancer-controller
cat > /tmp/lbc-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/$OIDC_HOST"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "$OIDC_HOST:aud":"sts.amazonaws.com",
   "$OIDC_HOST:sub":"system:serviceaccount:kube-system:aws-load-balancer-controller"}}}]}
EOF
aws iam create-role --role-name AWSLoadBalancerControllerRole \
  --assume-role-policy-document file:///tmp/lbc-trust.json
aws iam attach-role-policy --role-name AWSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy
LBC_ROLE_ARN=$(aws iam get-role --role-name AWSLoadBalancerControllerRole --query 'Role.Arn' --output text)

# Installer via Helm
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$PROJECT-cluster \
  --set vpcId=$VPC_ID \
  --set region=$AWS_REGION \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LBC_ROLE_ARN

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
# → 2 pods READY 1/1
```

### 7.6 Règles de Security Groups post-EKS

```bash
# SG des nœuds Auto Mode = cluster security group (créé automatiquement)
SG_EKS_NODES=$(aws eks describe-cluster --name "$PROJECT-cluster" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# A. RDS :3306 ← nœuds EKS
aws ec2 authorize-security-group-ingress --group-id $SG_RDS \
  --protocol tcp --port 3306 --source-group $SG_EKS_NODES

# B. ALB interne EKS :80 ← frontend
#    Le SG de l'ALB interne (k8s-...-backend) est créé par le LBC après le déploiement
#    de l'Ingress ($8). Ajoutez ensuite : autorise :80 depuis $SG_FRONTEND.
echo "SG nœuds EKS : $SG_EKS_NODES"
```

### 7.7 Rôle IRSA pour AWS Secrets Manager (Secrets Store CSI)

Le chart consomme les secrets via le **Secrets Store CSI Driver** (add-on ASCP $7.4). Les pods utilisent le ServiceAccount `ecommerce/ecommerce-sa`, annoté avec ce rôle IRSA qui autorise la lecture des 2 secrets.

```bash
DB_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$PROJECT/db/credentials"  --query ARN --output text)
JWT_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$PROJECT/jwt/secret"      --query ARN --output text)

cat > /tmp/secrets-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/$OIDC_HOST"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "$OIDC_HOST:aud":"sts.amazonaws.com",
   "$OIDC_HOST:sub":"system:serviceaccount:ecommerce:ecommerce-sa"}}}]}
EOF
aws iam create-role --role-name "$PROJECT-eks-secrets-role" \
  --assume-role-policy-document file:///tmp/secrets-trust.json

cat > /tmp/secrets-policy.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
 "Resource":["$DB_SECRET_ARN","$JWT_SECRET_ARN"]}]}
EOF
aws iam put-role-policy --role-name "$PROJECT-eks-secrets-role" \
  --policy-name secrets-read --policy-document file:///tmp/secrets-policy.json

SECRETS_ROLE_ARN=$(aws iam get-role --role-name "$PROJECT-eks-secrets-role" --query 'Role.Arn' --output text)
echo "Rôle secrets IRSA : $SECRETS_ROLE_ARN"
```

---

## 8. Déploiement Helm des microservices (GHCR)

Les microservices viennent de **GHCR public** - aucun secret de registry. L'Ingress du chart crée l'**ALB interne** via le LBC. Les secrets (DB_USER/DB_PASSWORD/JWT_SECRET) sont injectés depuis **AWS Secrets Manager** via le CSI Driver (mode `awsSecretsManager.enabled=true`, défaut du chart).

```bash
git clone https://github.com/yaraportfolio/ecommerce-k8s-helm.git
cd ecommerce-k8s-helm

kubectl create namespace ecommerce

helm install ecommerce-microservices . \
  --namespace ecommerce \
  --set image.registryType=ghcr \
  --set image.ghcr.registry=ghcr.io \
  --set image.ghcr.owner=yaraportfolio \
  --set database.host=$DB_ENDPOINT \
  --set database.name=$DB_NAME \
  --set awsSecretsManager.enabled=true \
  --set awsSecretsManager.region=$AWS_REGION \
  --set awsSecretsManager.iamRoleArn=$SECRETS_ROLE_ARN

# Vérifier (~2-3min) : 8 pods Running (2 × auth/product/order/review)
kubectl get pods -n ecommerce

# ALB interne (préfixe "internal-" = privé ✅)
kubectl get ingress -n ecommerce
INTERNAL_ALB=$(kubectl get ingress -n ecommerce \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
export INTERNAL_ALB
echo "ALB interne EKS : $INTERNAL_ALB"
```

> ℹ️ **L'ALB interne est privé** (accessible uniquement dans le VPC). C'est le comportement attendu : seul le frontend l'atteint.

**Test depuis l'intérieur du cluster :**
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n ecommerce \
  -- curl -s http://$INTERNAL_ALB/api/auth/health
# → {"status":"ok","database":"connected"}
```

> ⚠️ Après que le LBC ait créé le SG de l'ALB interne, complétez la règle **$7.6.B** : `:80 ← $SG_FRONTEND`.

---

## 9. ALB Public & Routing

Point d'entrée internet unique. **À créer avant les options frontend** (elles s'y attachent).

### Target Group + ALB public

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name "$PROJECT-tg-frontend" --protocol HTTP --port 80 \
  --vpc-id $VPC_ID --target-type instance \
  --health-check-path "/" --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Stickiness OBLIGATOIRE : chaque plateforme sert un build React au hash différent.
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes Key=stickiness.enabled,Value=true \
               Key=stickiness.type,Value=lb_cookie \
               Key=stickiness.lb_cookie.duration_seconds,Value=86400

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$PROJECT-alb-pub" --type application --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets ${SUBNET_PUB[a]} ${SUBNET_PUB[b]} ${SUBNET_PUB[c]} \
  --security-groups $SG_ALB \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
export ALB_DNS
echo "ALB public : $ALB_DNS"
```

### Listeners (HTTP→HTTPS + HTTPS forward)

```bash
# Certificat ACM (validation DNS via Cloudflare) :
# aws acm request-certificate --domain-name ecommerce.mondomaine.app --validation-method DNS
CERT_ARN="arn:aws:acm:$AWS_REGION:$AWS_ACCOUNT_ID:certificate/VOTRE-CERT-ID"

aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
  --default-actions "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"

aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTPS --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN"

echo "✅ ALB configuré : https://$ALB_DNS"
```

> 💡 Pour servir **les 3 options derrière le même ALB**, le listener 443 fait un *forward pondéré* vers `ecommerce-tg-frontend` (EC2+Beanstalk, poids 2) et `ecs-gateway-tg` (ECS, poids 1, créé en $12), avec **group stickiness** activée sur la règle.

---

## 10. Frontend Option A - EC2 (NGINX natif)

**Instance unique** (pas d'ASG). NGINX **natif**, build React fait sur la VM (sans Docker). Badge `VITE_DEPLOY_PLATFORM=ec2`.

### Rôle IAM + instance

```bash
cat > /tmp/ec2-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name "$PROJECT-frontend-ec2-role" \
  --assume-role-policy-document file:///tmp/ec2-trust.json
aws iam attach-role-policy --role-name "$PROJECT-frontend-ec2-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$PROJECT-frontend-ec2-profile"
aws iam add-role-to-instance-profile --instance-profile-name "$PROJECT-frontend-ec2-profile" \
  --role-name "$PROJECT-frontend-ec2-role"

cat > /tmp/frontend-userdata.sh << USERDATA
#!/bin/bash
ALB_URL="http://$INTERNAL_ALB"
dnf update -y && dnf install -y nginx git nodejs npm
cd /opt && git clone https://github.com/yaraportfolio/ecommerce-frontend.git
cd ecommerce-frontend
echo "VITE_DEPLOY_PLATFORM=ec2" > .env.production
npm ci && npm run build
cp -r dist/* /usr/share/nginx/html/
cat > /etc/nginx/conf.d/ecommerce.conf << 'NGINXEOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
    location /api/ { proxy_pass ALB_PLACEHOLDER/api/; proxy_set_header Host \$host; }
}
NGINXEOF
sed -i "s|ALB_PLACEHOLDER|\${ALB_URL}|g" /etc/nginx/conf.d/ecommerce.conf
systemctl enable --now nginx
USERDATA

AMI=$(aws ec2 describe-images --owners amazon \
  --filters 'Name=name,Values=al2023-ami-*-x86_64' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI --instance-type t3.micro \
  --iam-instance-profile Name="$PROJECT-frontend-ec2-profile" \
  --security-group-ids $SG_FRONTEND --subnet-id ${SUBNET_PUB[a]} \
  --associate-public-ip-address \
  --user-data file:///tmp/frontend-userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT-frontend-ec2}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "EC2 : $INSTANCE_ID (build ~4-5min)"
```

### Attacher au Target Group

```bash
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=80
# Attendre 'healthy'
aws elbv2 wait target-in-service --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID
```

> Accès debug : `aws ssm start-session --target $INSTANCE_ID` (aucune clé SSH).

---

## 11. Frontend Option B - Elastic Beanstalk

PaaS géré, **Single instance**, image Docker frontend depuis **ECR**. Badge `VITE_DEPLOY_PLATFORM=beanstalk`.

### Builder et pousser l'image ECR

```bash
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT/frontend"
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

cd ecommerce-frontend
docker build --build-arg VITE_DEPLOY_PLATFORM=beanstalk \
  -f docker/Dockerfile -t $ECR_URI:latest .
docker push $ECR_URI:latest
```

### Rôles IAM Beanstalk

Deux rôles sont requis : le **profil d'instance EC2** (SSM + WebTier + pull ECR) et le **rôle de service** (health + managed updates).

```bash
# --- Rôle d'instance EC2 + instance profile ---
cat > /tmp/eb-ec2-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name "$PROJECT-beanstalk-ec2-role" \
  --assume-role-policy-document file:///tmp/eb-ec2-trust.json
for P in AmazonSSMManagedInstanceCore AWSElasticBeanstalkWebTier AmazonEC2ContainerRegistryReadOnly; do
  aws iam attach-role-policy --role-name "$PROJECT-beanstalk-ec2-role" \
    --policy-arn arn:aws:iam::aws:policy/$P
done
aws iam create-instance-profile --instance-profile-name "$PROJECT-beanstalk-ec2-role"
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROJECT-beanstalk-ec2-role" \
  --role-name "$PROJECT-beanstalk-ec2-role"

# --- Rôle de service Beanstalk ---
cat > /tmp/eb-service-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"elasticbeanstalk.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name "$PROJECT-beanstalk-service-role" \
  --assume-role-policy-document file:///tmp/eb-service-trust.json
aws iam attach-role-policy --role-name "$PROJECT-beanstalk-service-role" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth
aws iam attach-role-policy --role-name "$PROJECT-beanstalk-service-role" \
  --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy
```

### Application + environnement (Single instance)

```bash
aws elasticbeanstalk create-application --application-name "$PROJECT-frontend"

cat > /tmp/Dockerrun.aws.json << EOF
{
  "AWSEBDockerrunVersion": "1",
  "Image": { "Name": "$ECR_URI:latest", "Update": "true" },
  "Ports": [{ "ContainerPort": "80" }],
  "Environment": [
    { "Name": "BACKEND_URL",  "Value": "http://$INTERNAL_ALB" },
    { "Name": "BACKEND_HOST", "Value": "ecommerce.mondomaine.app" }
  ]
}
EOF

S3_BUCKET="$PROJECT-eb-deployments-$AWS_ACCOUNT_ID"
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION
aws s3 cp /tmp/Dockerrun.aws.json s3://$S3_BUCKET/frontend/Dockerrun.aws.json

aws elasticbeanstalk create-application-version \
  --application-name "$PROJECT-frontend" --version-label "v1.0" \
  --source-bundle S3Bucket=$S3_BUCKET,S3Key=frontend/Dockerrun.aws.json

# Résoudre dynamiquement le dernier solution stack Docker AL2023 (évite une version codée en dur)
EB_STACK=$(aws elasticbeanstalk list-available-solution-stacks \
  --query "SolutionStacks[?contains(@,'running Docker') && contains(@,'Amazon Linux 2023')] | [0]" \
  --output text)

aws elasticbeanstalk create-environment \
  --application-name "$PROJECT-frontend" \
  --environment-name "$PROJECT-frontend-prod" \
  --solution-stack-name "$EB_STACK" \
  --version-label "v1.0" \
  --option-settings \
    Namespace=aws:elasticbeanstalk:environment,OptionName=EnvironmentType,Value=SingleInstance \
    Namespace=aws:elasticbeanstalk:environment,OptionName=ServiceRole,Value=$PROJECT-beanstalk-service-role \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=InstanceType,Value=t3.micro \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=SecurityGroups,Value=$SG_FRONTEND \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value=$PROJECT-beanstalk-ec2-role \
    Namespace=aws:ec2:vpc,OptionName=VPCId,Value=$VPC_ID \
    Namespace=aws:ec2:vpc,OptionName=Subnets,Value="${SUBNET_PUB[a]},${SUBNET_PUB[b]},${SUBNET_PUB[c]}" \
    Namespace=aws:ec2:vpc,OptionName=AssociatePublicIpAddress,Value=true

echo "Beanstalk en déploiement (~5min)..."
```

> Une fois l'environnement **Health: Ok**, enregistrez son instance EC2 dans `ecommerce-tg-frontend` (comme $10) pour la servir via l'ALB public.

---

## 12. Frontend Option C - ECS Fargate

Conteneurs sans serveur. Image dédiée taguée `:ecs` (le badge est **build-time**).

### Image ECR `:ecs`

```bash
docker build --build-arg VITE_DEPLOY_PLATFORM=ecs \
  -f docker/Dockerfile -t $ECR_URI:ecs .
docker push $ECR_URI:ecs
```

### Cluster + Task Definition + Service

```bash
aws ecs create-cluster --cluster-name "$PROJECT-frontend-cluster" \
  --capacity-providers FARGATE FARGATE_SPOT

aws logs create-log-group --log-group-name "/ecs/$PROJECT-frontend" 2>/dev/null || true

cat > /tmp/ecs-task-def.json << EOF
{
  "family": "$PROJECT-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256", "memory": "512",
  "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "frontend",
    "image": "$ECR_URI:ecs",
    "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
    "environment": [
      {"name": "BACKEND_URL",  "value": "http://$INTERNAL_ALB"},
      {"name": "BACKEND_HOST", "value": "ecommerce.mondomaine.app"}
    ],
    "logConfiguration": {"logDriver": "awslogs",
      "options": {"awslogs-group": "/ecs/$PROJECT-frontend",
                  "awslogs-region": "$AWS_REGION", "awslogs-stream-prefix": "ecs"}}
  }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/ecs-task-def.json

# TG type IP pour Fargate
TG_ECS_ARN=$(aws elbv2 create-target-group \
  --name "$PROJECT-ecs-gateway-tg" --protocol HTTP --port 80 \
  --vpc-id $VPC_ID --target-type ip --health-check-path "/" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ECS_ARN \
  --attributes Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie

aws ecs create-service \
  --cluster "$PROJECT-frontend-cluster" --service-name "$PROJECT-frontend-svc" \
  --task-definition "$PROJECT-frontend" --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_PUB[a]},${SUBNET_PUB[b]},${SUBNET_PUB[c]}],securityGroups=[$SG_FRONTEND],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ECS_ARN,containerName=frontend,containerPort=80"
echo "✅ Service ECS déployé"
```

### Ajouter le TG ECS au listener 443 (forward pondéré)

```bash
HTTPS_LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN \
  --query "Listeners[?Port==\`443\`].ListenerArn" --output text)
aws elbv2 modify-listener --listener-arn $HTTPS_LISTENER \
  --default-actions "Type=forward,ForwardConfig={TargetGroups=[\
{TargetGroupArn=$TG_ARN,Weight=2},{TargetGroupArn=$TG_ECS_ARN,Weight=1}],\
TargetGroupStickinessConfig={Enabled=true,DurationSeconds=86400}}"
```

> 💡 Express Mode (console) crée un ALB dédié qu'on supprime ; en CLI on attache directement le TG IP au listener partagé.

---

## 13. CloudFront + DNS (optionnel)

> ℹ️ **Optionnel - non déployé dans ce portfolio.** Le DNS est sur **Cloudflare** (CNAME → ALB public). CloudFront ajouterait un CDN + WAF devant l'ALB.

**DNS Cloudflare (déployé) :**
```
ecommerce.mondomaine.app  CNAME  <ALB_DNS>   (mode "DNS only", sans proxy)
```

**CloudFront (référence) :** distribution avec origin = ALB public, certificat ACM en **`us-east-1`** (contrainte CloudFront), puis CNAME Cloudflare → domaine CloudFront. Voir [$12 du guide console](./GUIDE-CONSOLE-AWS.md#12-cloudfront-optionnel).

> ⚠️ Avec CloudFront en cache, le badge multi-plateforme (EC2/Beanstalk/ECS) peut être masqué - pointez le domaine directement sur l'ALB pour garder le démo visible.

---

## 14. Vérification End-to-End

```bash
echo "=== VÉRIFICATION COMPLÈTE ==="

# 1. EKS - microservices
kubectl get pods -n ecommerce          # 8 pods Running
kubectl get hpa -n ecommerce           # HPA actifs (Metrics Server requis)

# 2. ALB interne (depuis le cluster)
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n ecommerce \
  -- curl -s http://$INTERNAL_ALB/api/auth/health

# 3. ALB public
curl -s -o /dev/null -w "ALB public : HTTP %{http_code}\n" http://$ALB_DNS/

# 4. Targets frontend
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text

echo "✅ Frontend : https://ecommerce.mondomaine.app"
```

---

## Résumé des endpoints

| Service | URL |
|---------|-----|
| Frontend public | `https://ecommerce.mondomaine.app/` |
| Auth API | `…/api/auth/` |
| Products API | `…/api/products/` |
| Orders API | `…/api/orders/` |
| Reviews API | `…/api/reviews/` |
| Health checks | `…/api/auth/health` |

## Comptes de test

| Rôle | Email | Mot de passe |
|------|-------|-------------|
| Utilisateur | john.doe@example.com | password123 |
| Administrateur | admin@ecommerce.com | admin123 |

---

**Prochaine étape → Terraform** : tout ce qui précède est codifié dans [`terraform/`](../terraform/) (modules `vpc`, `sg`, `rds`, `ecr`, `eks` Auto Mode, `alb`, `frontend-*`). CloudFront/observability sont documentés mais **non déployés** (donc hors Terraform).

---

## Annexe A - HPA : vérification et test

```bash
kubectl get hpa -n ecommerce
# NAME              REFERENCE                    TARGETS   MINPODS   MAXPODS   REPLICAS
# auth-service      Deployment/auth-service      12%/70%   1         3         1
# product-service   Deployment/product-service   8%/70%    1         3         1
# order-service     Deployment/order-service     5%/70%    1         3         1
# review-service    Deployment/review-service    4%/70%    1         2         1

# Test scale-out (charge artificielle)
kubectl run load-test --image=busybox -n ecommerce \
  -- sh -c "while true; do wget -qO- http://product-service:3002/api/products; done"
kubectl get hpa product-service -n ecommerce -w
kubectl delete pod load-test -n ecommerce
```

> ℹ️ Le HPA s'appuie sur le **Metrics Server** (add-on $7.4). Quand les pods pending ne tiennent pas sur les nœuds, **EKS Auto Mode provisionne automatiquement un nœud** (~1-2 min) - pas de Cluster Autoscaler à gérer.

---

## Annexe B - Optimisation des coûts (portfolio)

| Action | Commande |
|--------|----------|
| Éteindre le frontend EC2 | `aws ec2 stop-instances --instance-ids $INSTANCE_ID` |
| Scale microservices à 0 | `kubectl scale deploy -n ecommerce --all --replicas=0` (Auto Mode retire les nœuds) |
| Stopper RDS | `aws rds stop-db-instance --db-instance-identifier $PROJECT-mysql` |
| ECS à 0 task | `aws ecs update-service --cluster $PROJECT-frontend-cluster --service $PROJECT-frontend-svc --desired-count 0` |

> 💡 Incompressibles en continu : **EKS control plane (~$73) + ALB (~$16) + NAT (~$33) ≈ $120/mois**. Tout le reste peut être éteint hors démos.

---

*Ce guide CLI complète le [Guide Console AWS](./GUIDE-CONSOLE-AWS.md), l'[Architecture détaillée](./ARCHITECTURE.md) et le [Terraform](../terraform/). Les trois déploient la même architecture.*
