# Guide de Déploiement Manuel AWS — E-Commerce Microservices
**Auteur :** Yara Mahi Mohamed  
**Stack :** React 18 + NGINX | Node.js 20 microservices | MariaDB → RDS Aurora | EKS + Helm  
**Objectif :** Déployer manuellement pour comprendre chaque couche avant d'automatiser avec Terraform

---

## Sommaire

1. [Prérequis & Configuration AWS CLI](#1-prérequis--configuration-aws-cli)
2. [VPC & Réseau](#2-vpc--réseau)
3. [Security Groups](#3-security-groups)
4. [RDS Aurora (MySQL compatible MariaDB)](#4-rds-aurora-mysql-compatible-mariadb)
5. [ECR — Registry des images Docker](#5-ecr--registry-des-images-docker)
6. [EKS — Cluster Kubernetes (microservices)](#6-eks--cluster-kubernetes-microservices)
7. [Déploiement Helm sur EKS](#7-déploiement-helm-sur-eks)
8. [Frontend — Option A : EC2 + ASG](#8-frontend--option-a--ec2--asg)
9. [Frontend — Option B : Elastic Beanstalk](#9-frontend--option-b--elastic-beanstalk)
10. [Frontend — Option C : ECS Fargate](#10-frontend--option-c--ecs-fargate)
11. [ALB Public & Routing](#11-alb-public--routing)
12. [CloudFront + Route 53](#12-cloudfront--route-53)
13. [Vérification End-to-End](#13-vérification-end-to-end)

---

## Variables globales à définir

Avant de commencer, exportez ces variables dans votre terminal. Elles seront réutilisées dans toutes les commandes.

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
export DB_PASSWORD="CHANGEZ_MOI_db_password_32chars"  # ⚠️ Changez ceci

# JWT (même secret pour tous les services)
export JWT_SECRET="CHANGEZ_MOI_jwt_secret_min_32_chars"  # ⚠️ Changez ceci

echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"
```

---

## 1. Prérequis & Configuration AWS CLI

### Outils requis

```bash
# Vérifier les installations
aws --version          # >= 2.x
kubectl version        # >= 1.28
helm version           # >= 3.x
eksctl version         # >= 0.180
docker --version       # >= 20.10
jq --version           # pour parser le JSON
```

### Installation rapide (Ubuntu/Debian)

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# eksctl
curl --silent --location \
  "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
  | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Configurer AWS CLI

```bash
aws configure
# AWS Access Key ID: <votre_access_key>
# AWS Secret Access Key: <votre_secret_key>
# Default region name: eu-west-1
# Default output format: json

# Vérifier
aws sts get-caller-identity
```

---

## 2. VPC & Réseau

Architecture réseau : 3 AZ, subnets publics (frontend + ALB), subnets privés (EKS + RDS).

### Créer le VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc},{Key=Env,Value=$ENV}]" \
  --query 'Vpc.VpcId' --output text)

echo "VPC créé : $VPC_ID"

# Activer les hostnames DNS (requis pour RDS et EKS)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"
```

### Internet Gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
echo "IGW : $IGW_ID"
```

### Subnets publics (3 AZ)

```bash
# AZ-a — subnet public frontend + ALB
SUBNET_PUB_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.1.0/24" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-pub-a},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_PUB_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.2.0/24" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-pub-b},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_PUB_C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.3.0/24" \
  --availability-zone "${AWS_REGION}c" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-pub-c},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

# Activer l'assignation automatique d'IP publique
for SUBNET in $SUBNET_PUB_A $SUBNET_PUB_B $SUBNET_PUB_C; do
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET --map-public-ip-on-launch
done

echo "Subnets publics : $SUBNET_PUB_A | $SUBNET_PUB_B | $SUBNET_PUB_C"
```

### Subnets privés (EKS + microservices)

```bash
SUBNET_PRIV_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.10.0/24" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-priv-a},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_PRIV_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.11.0/24" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-priv-b},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_PRIV_C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.12.0/24" \
  --availability-zone "${AWS_REGION}c" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-priv-c},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

echo "Subnets privés : $SUBNET_PRIV_A | $SUBNET_PRIV_B | $SUBNET_PRIV_C"
```

### Subnets base de données (isolation maximale)

```bash
SUBNET_DB_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.20.0/24" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-db-a}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_DB_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.21.0/24" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-db-b}]" \
  --query 'Subnet.SubnetId' --output text)

echo "Subnets DB : $SUBNET_DB_A | $SUBNET_DB_B"
```

### NAT Gateway (sortie internet pour les pods EKS)

```bash
# Elastic IP pour la NAT GW (une par AZ pour la résilience)
EIP_A=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
EIP_B=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)

NAT_A=$(aws ec2 create-nat-gateway \
  --subnet-id $SUBNET_PUB_A \
  --allocation-id $EIP_A \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-a}]" \
  --query 'NatGateway.NatGatewayId' --output text)

NAT_B=$(aws ec2 create-nat-gateway \
  --subnet-id $SUBNET_PUB_B \
  --allocation-id $EIP_B \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$PROJECT-nat-b}]" \
  --query 'NatGateway.NatGatewayId' --output text)

echo "Attente NAT Gateway (~60s)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_B
echo "NAT GW : $NAT_A | $NAT_B"
```

### Tables de routage

```bash
# Route table publique → IGW
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-pub}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id $RT_PUB \
  --destination-cidr-block "0.0.0.0/0" --gateway-id $IGW_ID

for SUBNET in $SUBNET_PUB_A $SUBNET_PUB_B $SUBNET_PUB_C; do
  aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $SUBNET
done

# Route tables privées → NAT GW (une par AZ)
RT_PRIV_A=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-priv-a}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRIV_A \
  --destination-cidr-block "0.0.0.0/0" --nat-gateway-id $NAT_A
aws ec2 associate-route-table --route-table-id $RT_PRIV_A --subnet-id $SUBNET_PRIV_A
aws ec2 associate-route-table --route-table-id $RT_PRIV_A --subnet-id $SUBNET_DB_A

RT_PRIV_B=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-rt-priv-b}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRIV_B \
  --destination-cidr-block "0.0.0.0/0" --nat-gateway-id $NAT_B
aws ec2 associate-route-table --route-table-id $RT_PRIV_B --subnet-id $SUBNET_PRIV_B
aws ec2 associate-route-table --route-table-id $RT_PRIV_B --subnet-id $SUBNET_DB_B

echo "✅ Réseau complet"
```

---

## 3. Security Groups

Règle d'or : les SGs référencent d'autres SGs (pas des CIDRs) pour les communications internes.

### SG — ALB public (frontend)

```bash
SG_ALB=$(aws ec2 create-security-group \
  --group-name "$PROJECT-sg-alb" \
  --description "ALB public - HTTPS/HTTP depuis internet" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-alb}]" \
  --query 'GroupId' --output text)

# HTTP et HTTPS depuis n'importe où
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

echo "SG ALB : $SG_ALB"
```

### SG — Frontend EC2 / Beanstalk / ECS

```bash
SG_FRONTEND=$(aws ec2 create-security-group \
  --group-name "$PROJECT-sg-frontend" \
  --description "Frontend - trafic depuis ALB uniquement" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-frontend}]" \
  --query 'GroupId' --output text)

# Port 80 uniquement depuis l'ALB (référence SG, pas CIDR)
aws ec2 authorize-security-group-ingress --group-id $SG_FRONTEND \
  --protocol tcp --port 80 --source-group $SG_ALB

echo "SG Frontend : $SG_FRONTEND"
```

### SG — EKS Nodes (microservices)

```bash
SG_EKS=$(aws ec2 create-security-group \
  --group-name "$PROJECT-sg-eks" \
  --description "EKS nodes - ports microservices depuis frontend" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-eks}]" \
  --query 'GroupId' --output text)

# Ports microservices depuis le frontend uniquement
for PORT in 3001 3002 3003 3004; do
  aws ec2 authorize-security-group-ingress --group-id $SG_EKS \
    --protocol tcp --port $PORT --source-group $SG_FRONTEND
done

# Communication intra-cluster (self-reference)
aws ec2 authorize-security-group-ingress --group-id $SG_EKS \
  --protocol -1 --source-group $SG_EKS

echo "SG EKS : $SG_EKS"
```

### SG — RDS (base de données)

```bash
SG_RDS=$(aws ec2 create-security-group \
  --group-name "$PROJECT-sg-rds" \
  --description "RDS Aurora - MySQL depuis EKS uniquement" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT-sg-rds}]" \
  --query 'GroupId' --output text)

# MySQL/MariaDB port 3306 uniquement depuis les pods EKS
aws ec2 authorize-security-group-ingress --group-id $SG_RDS \
  --protocol tcp --port 3306 --source-group $SG_EKS

echo "SG RDS : $SG_RDS"
```

---

## 4. RDS Aurora (MySQL compatible MariaDB)

Aurora MySQL est compatible avec MariaDB 10.11 — vos schémas et drivers `mysql2` fonctionnent sans modification.

### Stocker les secrets dans AWS Secrets Manager

```bash
# Créer le secret DB (évite de mettre le mot de passe en clair dans les commandes)
aws secretsmanager create-secret \
  --name "$PROJECT/db/credentials" \
  --description "Credentials RDS Aurora ecommerce" \
  --secret-string "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASSWORD\"}"

echo "Secret DB créé dans Secrets Manager"
```

### Subnet group RDS

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$PROJECT-db-subnet-group" \
  --db-subnet-group-description "Subnets pour RDS Aurora $PROJECT" \
  --subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
  --tags Key=Name,Value=$PROJECT-db-subnet-group

echo "Subnet group RDS créé"
```

### Cluster Aurora MySQL

```bash
# Créer le cluster Aurora (compatible MySQL 8.0 ≈ MariaDB 10.11)
aws rds create-db-cluster \
  --db-cluster-identifier "$PROJECT-aurora-cluster" \
  --engine aurora-mysql \
  --engine-version "8.0.mysql_aurora.3.05.2" \
  --master-username $DB_USER \
  --master-user-password $DB_PASSWORD \
  --database-name $DB_NAME \
  --db-subnet-group-name "$PROJECT-db-subnet-group" \
  --vpc-security-group-ids $SG_RDS \
  --backup-retention-period 7 \
  --preferred-backup-window "02:00-03:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --storage-encrypted \
  --no-deletion-protection \
  --tags Key=Name,Value=$PROJECT-aurora-cluster Key=Env,Value=$ENV

echo "Cluster Aurora en création (~5min)..."
```

### Instance primaire Aurora

```bash
aws rds create-db-instance \
  --db-instance-identifier "$PROJECT-aurora-primary" \
  --db-cluster-identifier "$PROJECT-aurora-cluster" \
  --db-instance-class "db.t3.medium" \
  --engine aurora-mysql \
  --publicly-accessible false \
  --tags Key=Name,Value=$PROJECT-aurora-primary Key=Env,Value=$ENV

# Attendre que l'instance soit disponible (~8min)
echo "Attente instance Aurora (~8min)..."
aws rds wait db-instance-available \
  --db-instance-identifier "$PROJECT-aurora-primary"

# Récupérer l'endpoint
DB_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$PROJECT-aurora-cluster" \
  --query 'DBClusters[0].Endpoint' --output text)

echo "✅ RDS Aurora endpoint : $DB_ENDPOINT"
export DB_ENDPOINT
```

### Initialiser la base de données

```bash
# Depuis un bastion ou depuis votre machine (si accès VPN/tunnel)
# Option simple : utiliser AWS Systems Manager Session Manager sur un EC2 bastion

# Installer le schéma
mysql -h $DB_ENDPOINT -u $DB_USER -p$DB_PASSWORD $DB_NAME \
  < ecommerce_db.sql

echo "✅ Schéma importé"
```

---

## 5. ECR — Registry des images Docker

Les images sont sur GHCR publiquement, mais pour la prod AWS on les copie sur ECR.

### Créer les repositories ECR

```bash
for SERVICE in auth-service product-service order-service review-service frontend; do
  aws ecr create-repository \
    --repository-name "$PROJECT/$SERVICE" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags Key=Name,Value=$PROJECT-$SERVICE Key=Env,Value=$ENV
  echo "ECR créé : $PROJECT/$SERVICE"
done
```

### Authentification Docker → ECR

```bash
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS \
  --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

echo "✅ Docker authentifié sur ECR"
```

### Copier les images de GHCR vers ECR

```bash
ECR_BASE="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT"
GHCR_BASE="ghcr.io/yaraportfolio"
VERSION="v3.3"

for SERVICE in auth-service product-service order-service review-service; do
  echo "Migration $SERVICE..."
  docker pull $GHCR_BASE/$SERVICE:$VERSION
  docker tag $GHCR_BASE/$SERVICE:$VERSION $ECR_BASE/$SERVICE:$VERSION
  docker tag $GHCR_BASE/$SERVICE:$VERSION $ECR_BASE/$SERVICE:latest
  docker push $ECR_BASE/$SERVICE:$VERSION
  docker push $ECR_BASE/$SERVICE:latest
  echo "✅ $SERVICE pushé sur ECR"
done
```

### Builder et pousser le frontend

```bash
cd ecommerce-frontend

# Builder l'image (NGINX + React build multi-stage)
docker build -f docker/Dockerfile \
  -t $ECR_BASE/frontend:latest \
  -t $ECR_BASE/frontend:v1.0 \
  .

docker push $ECR_BASE/frontend:latest
docker push $ECR_BASE/frontend:v1.0

echo "✅ Frontend pushé sur ECR"
cd ..
```

---

## 6. EKS — Cluster Kubernetes (microservices)

### Créer le cluster EKS avec eksctl

```bash
# Créer le fichier de configuration eksctl
cat > /tmp/eks-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $PROJECT-cluster
  region: $AWS_REGION
  version: "1.29"
  tags:
    Env: $ENV
    Project: $PROJECT

vpc:
  id: $VPC_ID
  subnets:
    private:
      ${AWS_REGION}a:
        id: $SUBNET_PRIV_A
      ${AWS_REGION}b:
        id: $SUBNET_PRIV_B

managedNodeGroups:
  - name: $PROJECT-nodes
    instanceType: t3.medium
    minSize: 2
    maxSize: 6
    desiredCapacity: 3
    privateNetworking: true
    securityGroups:
      attachIDs:
        - $SG_EKS
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    tags:
      Name: $PROJECT-node
      Env: $ENV

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
EOF

# Créer le cluster (~15min)
eksctl create cluster -f /tmp/eks-cluster.yaml
echo "Cluster EKS créé !"
```

### Configurer kubectl

```bash
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name $PROJECT-cluster

kubectl get nodes
# NAME                          STATUS   ROLES    AGE
# ip-10-0-10-x.eu-west-1...   Ready    <none>   2m
```

### Installer le AWS Load Balancer Controller (pour l'ALB interne EKS)

```bash
# OIDC provider
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster $PROJECT-cluster \
  --approve

# Policy IAM pour le LB Controller
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
  --cluster=$PROJECT-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Installer via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$PROJECT-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Créer le namespace et les secrets Kubernetes

```bash
kubectl create namespace ecommerce

# Secret DB + JWT (partagé par tous les microservices)
kubectl create secret generic ecommerce-secrets \
  --namespace ecommerce \
  --from-literal=DB_HOST=$DB_ENDPOINT \
  --from-literal=DB_PORT="3306" \
  --from-literal=DB_NAME=$DB_NAME \
  --from-literal=DB_USER=$DB_USER \
  --from-literal=DB_PASSWORD=$DB_PASSWORD \
  --from-literal=JWT_SECRET=$JWT_SECRET

kubectl get secret ecommerce-secrets -n ecommerce
echo "✅ Secrets Kubernetes créés"
```

---

## 7. Déploiement Helm sur EKS

### Adapter le values.yaml pour AWS

```bash
cat > /tmp/values-aws.yaml << EOF
# Registry AWS ECR (remplace GHCR)
image:
  registryType: ecr
  ecr:
    registry: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    owner: $PROJECT
  pullPolicy: Always
  imagePullSecrets:
    enabled: false  # Les nodes EKS ont déjà accès ECR via IAM

# Pas de password en clair ici — injecté via secretRef Kubernetes
database:
  host: "$DB_ENDPOINT"
  port: 3306
  name: "$DB_NAME"
  user: "$DB_USER"
  password: ""  # Injecté via ecommerce-secrets

jwt:
  secret: ""  # Injecté via ecommerce-secrets

services:
  authService:
    enabled: true
    name: auth-service
    image:
      tag: $VERSION
    port: 3001
    replicas: 2
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 8
      targetCPUUtilizationPercentage: 70

  productService:
    enabled: true
    name: product-service
    image:
      tag: $VERSION
    port: 3002
    replicas: 2
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 70

  orderService:
    enabled: true
    name: order-service
    image:
      tag: $VERSION
    port: 3003
    replicas: 2
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 6
      targetCPUUtilizationPercentage: 70

  reviewService:
    enabled: true
    name: review-service
    image:
      tag: $VERSION
    port: 3004
    replicas: 2
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 6
      targetCPUUtilizationPercentage: 70

monitoring:
  enabled: true
  serviceMonitor:
    enabled: false  # Activer si Prometheus Operator installé
EOF
```

### Déployer avec Helm

```bash
cd ecommerce-k8s-helm

helm install ecommerce-microservices . \
  --namespace ecommerce \
  --create-namespace \
  -f /tmp/values-aws.yaml

# Vérifier (~2min)
kubectl get pods -n ecommerce -w

# Résultat attendu :
# auth-service-xxx     Running   2/2
# product-service-xxx  Running   2/2
# order-service-xxx    Running   2/2
# review-service-xxx   Running   2/2
```

### Vérifier les services

```bash
kubectl get svc -n ecommerce

# Tester les health checks depuis l'intérieur du cluster
kubectl run test-pod --image=curlimages/curl --rm -it --restart=Never \
  -n ecommerce -- curl http://auth-service:3001/api/auth/health

# Résultat attendu : {"status":"ok","service":"auth-service"}
```

### Récupérer l'endpoint ALB interne EKS

```bash
# L'Ingress crée automatiquement un ALB interne via AWS LB Controller
kubectl get ingress -n ecommerce

INTERNAL_ALB=$(kubectl get ingress -n ecommerce \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

echo "ALB interne EKS : $INTERNAL_ALB"
export INTERNAL_ALB
```

---

## 8. Frontend — Option A : EC2 + ASG

EC2 classique avec Auto Scaling Group. Contrôle total, idéal pour comprendre le mécanisme de base.

### Créer le Launch Template

```bash
# User Data script : au démarrage de chaque EC2, il configure NGINX
cat > /tmp/frontend-userdata.sh << 'USERDATA'
#!/bin/bash
set -e

# Variables injectées via les tags EC2 ou SSM Parameter Store
BACKEND_URL=$(aws ssm get-parameter --name "/ecommerce/backend_url" \
  --query 'Parameter.Value' --output text --region eu-west-1)
BACKEND_HOST="api.ecommerce.local"

# Installer Docker
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user

# Login ECR
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS \
  --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-west-1.amazonaws.com

# Lancer le frontend
docker run -d \
  --name ecommerce-frontend \
  -p 80:80 \
  -e BACKEND_URL=$BACKEND_URL \
  -e BACKEND_HOST=$BACKEND_HOST \
  --restart always \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend:latest

echo "Frontend démarré"
USERDATA

# Stocker le BACKEND_URL dans SSM Parameter Store
aws ssm put-parameter \
  --name "/ecommerce/backend_url" \
  --value "http://$INTERNAL_ALB" \
  --type String \
  --overwrite

# Créer le Launch Template
LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "$PROJECT-frontend-lt" \
  --version-description "v1" \
  --launch-template-data "{
    \"ImageId\": \"$(aws ec2 describe-images \
      --owners amazon \
      --filters 'Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2' \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
      --output text)\",
    \"InstanceType\": \"t3.medium\",
    \"SecurityGroupIds\": [\"$SG_FRONTEND\"],
    \"IamInstanceProfile\": {\"Name\": \"$PROJECT-ec2-profile\"},
    \"UserData\": \"$(base64 -w0 /tmp/frontend-userdata.sh)\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$PROJECT-frontend\"}]
    }]
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "Launch Template : $LT_ID"
```

### Créer l'Auto Scaling Group

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$PROJECT-frontend-asg" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size 2 \
  --max-size 6 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$SUBNET_PUB_A,$SUBNET_PUB_B,$SUBNET_PUB_C" \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --tags "Key=Name,Value=$PROJECT-frontend,PropagateAtLaunch=true"

echo "✅ ASG EC2 créé"
```

---

## 9. Frontend — Option B : Elastic Beanstalk

PaaS géré. Beanstalk gère le provisionning EC2, l'ALB et l'autoscaling automatiquement.

### Créer l'application Beanstalk

```bash
aws elasticbeanstalk create-application \
  --application-name "$PROJECT-frontend" \
  --description "Frontend e-commerce React + NGINX"

# Créer le fichier Dockerrun.aws.json (configuration Docker pour Beanstalk)
cat > /tmp/Dockerrun.aws.json << EOF
{
  "AWSEBDockerrunVersion": "1",
  "Image": {
    "Name": "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT/frontend:latest",
    "Update": "true"
  },
  "Ports": [{ "ContainerPort": "80" }],
  "Environment": [
    { "Name": "BACKEND_URL", "Value": "http://$INTERNAL_ALB" },
    { "Name": "BACKEND_HOST", "Value": "api.ecommerce.local" }
  ]
}
EOF

# Uploader le bundle sur S3
S3_BUCKET="$PROJECT-eb-deployments-$AWS_ACCOUNT_ID"
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION
aws s3 cp /tmp/Dockerrun.aws.json s3://$S3_BUCKET/frontend/Dockerrun.aws.json

# Créer la version de l'application
aws elasticbeanstalk create-application-version \
  --application-name "$PROJECT-frontend" \
  --version-label "v1.0" \
  --source-bundle S3Bucket=$S3_BUCKET,S3Key=frontend/Dockerrun.aws.json

# Créer l'environnement Beanstalk
aws elasticbeanstalk create-environment \
  --application-name "$PROJECT-frontend" \
  --environment-name "$PROJECT-frontend-prod" \
  --solution-stack-name "64bit Amazon Linux 2 v3.8.0 running Docker" \
  --version-label "v1.0" \
  --option-settings \
    Namespace=aws:autoscaling:asg,OptionName=MinSize,Value=2 \
    Namespace=aws:autoscaling:asg,OptionName=MaxSize,Value=6 \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=InstanceType,Value=t3.medium \
    Namespace=aws:autoscaling:launchconfiguration,OptionName=SecurityGroups,Value=$SG_FRONTEND \
    Namespace=aws:ec2:vpc,OptionName=VPCId,Value=$VPC_ID \
    Namespace=aws:ec2:vpc,OptionName=Subnets,Value="$SUBNET_PUB_A,$SUBNET_PUB_B" \
    Namespace=aws:elasticbeanstalk:application:environment,OptionName=BACKEND_URL,Value="http://$INTERNAL_ALB"

echo "Beanstalk en déploiement (~5min)..."
```

---

## 10. Frontend — Option C : ECS Fargate

Conteneurs managés sans gérer de serveurs. Idéal pour comprendre le modèle serverless containers.

### Créer le cluster ECS

```bash
aws ecs create-cluster \
  --cluster-name "$PROJECT-frontend-cluster" \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy \
    capacityProvider=FARGATE,weight=1 \
    capacityProvider=FARGATE_SPOT,weight=4 \
  --tags key=Name,value=$PROJECT-frontend key=Env,value=$ENV

echo "Cluster ECS créé"
```

### Task Definition Fargate

```bash
cat > /tmp/ecs-task-def.json << EOF
{
  "family": "$PROJECT-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "frontend",
      "image": "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT/frontend:latest",
      "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
      "environment": [
        {"name": "BACKEND_URL", "value": "http://$INTERNAL_ALB"},
        {"name": "BACKEND_HOST", "value": "api.ecommerce.local"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$PROJECT-frontend",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      }
    }
  ]
}
EOF

# Créer le log group CloudWatch
aws logs create-log-group --log-group-name "/ecs/$PROJECT-frontend"

# Enregistrer la task definition
aws ecs register-task-definition --cli-input-json file:///tmp/ecs-task-def.json

echo "Task Definition ECS créée"
```

### ECS Service

```bash
# Créer un ALB dédié ECS (ou réutiliser celui de l'étape suivante)
aws ecs create-service \
  --cluster "$PROJECT-frontend-cluster" \
  --service-name "$PROJECT-frontend-svc" \
  --task-definition "$PROJECT-frontend" \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[$SUBNET_PUB_A,$SUBNET_PUB_B],
    securityGroups=[$SG_FRONTEND],
    assignPublicIp=ENABLED
  }" \
  --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100" \
  --tags key=Name,value=$PROJECT-frontend

echo "✅ Service ECS déployé"
```

---

## 11. ALB Public & Routing

L'ALB public est le point d'entrée unique. Il distribue le trafic vers le frontend (EC2, Beanstalk, ou ECS).

### Créer l'ALB public

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$PROJECT-alb-pub" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets $SUBNET_PUB_A $SUBNET_PUB_B $SUBNET_PUB_C \
  --security-groups $SG_ALB \
  --tags Key=Name,Value=$PROJECT-alb-pub Key=Env,Value=$ENV \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB public DNS : $ALB_DNS"
export ALB_DNS
```

### Target Group (exemple EC2)

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name "$PROJECT-tg-frontend" \
  --protocol HTTP \
  --port 80 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags Key=Name,Value=$PROJECT-tg-frontend \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Attacher l'ASG au Target Group
aws autoscaling attach-load-balancer-target-groups \
  --auto-scaling-group-name "$PROJECT-frontend-asg" \
  --target-group-arns $TG_ARN
```

### Listener HTTP → HTTPS (redirection)

```bash
# Listener HTTP port 80 → redirect HTTPS
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"

# Listener HTTPS port 443 → forward vers le frontend
# Note : vous devez avoir un certificat ACM pour votre domaine
# aws acm request-certificate --domain-name "ecommerce.votredomaine.com" --validation-method DNS
CERT_ARN="arn:aws:acm:$AWS_REGION:$AWS_ACCOUNT_ID:certificate/VOTRE-CERT-ID"

aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN"

echo "✅ ALB configuré : https://$ALB_DNS"
```

---

## 12. CloudFront + Route 53

CloudFront met le frontend en cache globalement. Route 53 pointe votre domaine vers CloudFront.

### Distribution CloudFront

```bash
aws cloudfront create-distribution \
  --distribution-config '{
    "CallerReference": "ecommerce-'$(date +%s)'",
    "Comment": "E-Commerce Frontend CDN",
    "DefaultRootObject": "index.html",
    "Origins": {
      "Quantity": 1,
      "Items": [{
        "Id": "ALB-Origin",
        "DomainName": "'$ALB_DNS'",
        "CustomOriginConfig": {
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "https-only",
          "OriginSSLProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
        }
      }]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "ALB-Origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
        "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
      "Compress": true
    },
    "Enabled": true,
    "PriceClass": "PriceClass_100"
  }' \
  --query 'Distribution.DomainName' --output text

echo "CloudFront en déploiement (~10min)..."
```

---

## 13. Vérification End-to-End

```bash
echo "=== VÉRIFICATION COMPLÈTE ==="

# 1. EKS — microservices
echo "--- Pods EKS ---"
kubectl get pods -n ecommerce

# 2. Microservices health checks
echo "--- Health checks microservices ---"
for SVC in auth products orders reviews; do
  STATUS=$(kubectl run test --image=curlimages/curl --rm -it --restart=Never -n ecommerce \
    -- curl -s -o /dev/null -w "%{http_code}" http://${SVC}-service:$(echo $SVC | sed 's/auth/3001/;s/products/3002/;s/orders/3003/;s/reviews/3004/')/api/$SVC/health 2>/dev/null)
  echo "  $SVC : HTTP $STATUS"
done

# 3. ALB public
echo "--- ALB public ---"
curl -s -o /dev/null -w "HTTP %{http_code}" http://$ALB_DNS/
echo ""

# 4. RDS
echo "--- RDS connexion ---"
mysql -h $DB_ENDPOINT -u $DB_USER -p$DB_PASSWORD $DB_NAME \
  -e "SELECT COUNT(*) as users FROM users;" 2>/dev/null

# 5. HPA
echo "--- HPA autoscaling ---"
kubectl get hpa -n ecommerce

echo ""
echo "✅ Déploiement manuel terminé !"
echo "Frontend : https://$ALB_DNS"
echo "API test : curl https://$ALB_DNS/api/products"
```

---

## Résumé des endpoints

| Service | URL |
|---------|-----|
| Frontend public | `https://<ALB_DNS>/` |
| Auth API | `https://<ALB_DNS>/api/auth/` |
| Products API | `https://<ALB_DNS>/api/products/` |
| Orders API | `https://<ALB_DNS>/api/orders/` |
| Reviews API | `https://<ALB_DNS>/api/reviews/` |
| Health checks | `https://<ALB_DNS>/api/auth/health` |

## Comptes de test

| Rôle | Email | Mot de passe |
|------|-------|-------------|
| Utilisateur | john.doe@example.com | password123 |
| Administrateur | admin@ecommerce.com | admin123 |

---

**Prochaine étape → Terraform** : Tout ce qui précède est codifié dans `terraform/` avec des modules réutilisables.

---

## Annexe A — Cluster Autoscaler

Le Cluster Autoscaler ajuste automatiquement le nombre de nodes EC2 dans le Node Group EKS selon les pods en attente de scheduling.

```bash
# Installer via Helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=$PROJECT-cluster \
  --set awsRegion=$AWS_REGION \
  --set rbac.serviceAccount.create=true

# Vérifier
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler --tail=20

# Tester : créer une charge artificielle et observer le scale-out
kubectl run stress --image=busybox --requests='cpu=500m' \
  --limits='cpu=500m' -- sleep 600
kubectl get nodes -w  # observer l'ajout d'un node en ~3 minutes
kubectl delete pod stress
```

**Tags requis sur le Node Group** (ajoutés automatiquement par Terraform) :
```
k8s.io/cluster-autoscaler/enabled = true
k8s.io/cluster-autoscaler/ecommerce-cluster = owned
```

---

## Annexe B — HPA : vérification et test

```bash
# État des HPA
kubectl get hpa -n ecommerce

# Résultat attendu :
# NAME              REFERENCE                    TARGETS   MINPODS   MAXPODS   REPLICAS
# auth-service      Deployment/auth-service      12%/70%   2         8         2
# product-service   Deployment/product-service   8%/70%    2         10        2
# order-service     Deployment/order-service     5%/70%    2         6         2
# review-service    Deployment/review-service    4%/70%    2         6         2

# Tester le scale-out (simuler une charge)
kubectl run load-test --image=busybox -n ecommerce \
  -- sh -c "while true; do wget -qO- http://product-service:3002/api/products; done"

# Observer le scaling en temps réel
kubectl get hpa product-service -n ecommerce -w

# Nettoyer
kubectl delete pod load-test -n ecommerce
```

**Prérequis pour que le HPA fonctionne :** le Metrics Server doit être installé.
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get deployment metrics-server -n kube-system
```

---

## Annexe C — Observabilité : VPC Flow Logs, CloudTrail, alarmes

### VPC Flow Logs

```bash
# Activer les Flow Logs sur le VPC (vers CloudWatch)
LOG_GROUP_ARN=$(aws logs create-log-group \
  --log-group-name "/aws/vpc/flowlogs/$PROJECT" \
  --query 'logGroupArn' --output text 2>/dev/null || \
  aws logs describe-log-groups \
  --log-group-name-prefix "/aws/vpc/flowlogs/$PROJECT" \
  --query 'logGroups[0].arn' --output text)

# Créer le rôle IAM pour les Flow Logs
FLOW_ROLE_ARN=$(aws iam create-role \
  --role-name "$PROJECT-vpc-flow-log-role" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"vpc-flow-logs.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' --query 'Role.Arn' --output text)

aws iam put-role-policy \
  --role-name "$PROJECT-vpc-flow-log-role" \
  --policy-name "flow-log-policy" \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"*"}]
  }'

# Activer les Flow Logs
aws ec2 create-flow-logs \
  --resource-ids $VPC_ID \
  --resource-type VPC \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name "/aws/vpc/flowlogs/$PROJECT" \
  --deliver-logs-permission-arn $FLOW_ROLE_ARN

echo "✅ VPC Flow Logs activés"
```

### CloudTrail

```bash
# Bucket S3 pour CloudTrail
TRAIL_BUCKET="$PROJECT-cloudtrail-$AWS_ACCOUNT_ID"
aws s3 mb s3://$TRAIL_BUCKET --region $AWS_REGION

# Politique bucket (obligatoire pour CloudTrail)
aws s3api put-bucket-policy --bucket $TRAIL_BUCKET --policy "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Sid\":\"AWSCloudTrailAclCheck\",\"Effect\":\"Allow\",
     \"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},
     \"Action\":\"s3:GetBucketAcl\",\"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET\"},
    {\"Sid\":\"AWSCloudTrailWrite\",\"Effect\":\"Allow\",
     \"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},
     \"Action\":\"s3:PutObject\",
     \"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/$AWS_ACCOUNT_ID/*\",
     \"Condition\":{\"StringEquals\":{\"s3:x-amz-acl\":\"bucket-owner-full-control\"}}}
  ]}"

# Créer le trail
aws cloudtrail create-trail \
  --name "$PROJECT-trail" \
  --s3-bucket-name $TRAIL_BUCKET \
  --include-global-service-events \
  --enable-log-file-validation

aws cloudtrail start-logging --name "$PROJECT-trail"
echo "✅ CloudTrail activé → s3://$TRAIL_BUCKET"
```

### Alarmes CloudWatch

```bash
# Alarme : trop d'erreurs 5xx sur l'ALB
ALB_ARN_SUFFIX=$(aws elbv2 describe-load-balancers \
  --names $PROJECT-alb-pub \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text | \
  sed 's|.*loadbalancer/||')

aws cloudwatch put-metric-alarm \
  --alarm-name "$PROJECT-alb-5xx-errors" \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --period 60 \
  --statistic Sum \
  --threshold 10 \
  --dimensions Name=LoadBalancer,Value=$ALB_ARN_SUFFIX \
  --alarm-description "Trop d'erreurs 5xx sur l'ALB"

# Alarme : CPU Aurora trop élevé
aws cloudwatch put-metric-alarm \
  --alarm-name "$PROJECT-rds-cpu-high" \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 3 \
  --metric-name CPUUtilization \
  --namespace AWS/RDS \
  --period 60 \
  --statistic Average \
  --threshold 80 \
  --dimensions Name=DBClusterIdentifier,Value=$PROJECT-aurora-cluster

# Dashboard CloudWatch
aws cloudwatch put-dashboard \
  --dashboard-name "$PROJECT-monitoring" \
  --dashboard-body file:///dev/stdin << 'DASHBOARD'
{
  "widgets": [
    {"type":"metric","properties":{"title":"ALB Requêtes/min","metrics":[["AWS/ApplicationELB","RequestCount","LoadBalancer","ALB_SUFFIX"]],"period":60,"stat":"Sum"},"width":12,"height":6,"x":0,"y":0},
    {"type":"metric","properties":{"title":"RDS CPU %","metrics":[["AWS/RDS","CPUUtilization","DBClusterIdentifier","ecommerce-aurora-cluster"]],"period":60,"stat":"Average"},"width":12,"height":6,"x":12,"y":0}
  ]
}
DASHBOARD

echo "✅ Alarmes et dashboard CloudWatch créés"
```

---

## Annexe D — ECR Lifecycle Policy

Éviter l'accumulation d'images non utilisées (facturation au GB stocké).

```bash
for SERVICE in auth-service product-service order-service review-service frontend; do
  aws ecr put-lifecycle-policy \
    --repository-name "$PROJECT/$SERVICE" \
    --lifecycle-policy-text '{
      "rules": [{
        "rulePriority": 1,
        "description": "Garder les 10 dernières images",
        "selection": {
          "tagStatus": "any",
          "countType": "imageCountMoreThan",
          "countNumber": 10
        },
        "action": { "type": "expire" }
      }]
    }'
  echo "Lifecycle policy ajoutée : $PROJECT/$SERVICE"
done
```

---

## Annexe E — AWS Load Balancer Controller (console Helm)

Requis pour que l'Ingress Kubernetes crée automatiquement l'ALB interne EKS.

```bash
# 1. Associer l'OIDC provider au cluster
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster $PROJECT-cluster \
  --approve

# 2. Télécharger la policy IAM
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# 3. Créer le ServiceAccount avec le rôle IAM attaché
eksctl create iamserviceaccount \
  --cluster=$PROJECT-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# 4. Installer via Helm
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$PROJECT-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# 5. Vérifier
kubectl get deployment -n kube-system aws-load-balancer-controller
# → 2/2 READY

# L'Ingress créé par Helm crée maintenant un ALB interne automatiquement
kubectl get ingress -n ecommerce
# → ADDRESS = internal-xxx.eu-west-1.elb.amazonaws.com
INTERNAL_ALB=$(kubectl get ingress -n ecommerce \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB interne EKS : $INTERNAL_ALB"
```
