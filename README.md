# AWS E-Commerce - Infrastructure as Code
**Auteur :** Yara Mahi Mohamed | Portfolio DevOps & SRE  
**Stack :** React 18 + NGINX | Node.js 20 microservices | RDS Aurora MySQL | EKS + Helm

---

## Vue d'ensemble

Ce projet déploie l'architecture e-commerce complète sur AWS en deux phases :

1. **Phase 1 - Déploiement manuel** : comprendre chaque service AWS avant d'automatiser
2. **Phase 2 - Terraform** : infrastructure as code modulaire et reproductible

### Architecture déployée

```
Internet → Route 53 → CloudFront → ALB public (HTTPS)
                                        │
                    ┌───────────────────┼──────────────────┐
                    │                   │                  │
               EC2 + ASG       Elastic Beanstalk    ECS Fargate
               (Option A)        (Option B)          (Option C)
                    └───────────────────┼──────────────────┘
                                        │ HTTP
                              ALB interne EKS
                                        │
                    ┌───────────────────┼──────────────────┐
                    │                   │                  │
              auth-service      product-service      order-service
               :3001             :3002                :3003
                    │                                      │
              review-service                      [HPA 2-8 pods]
               :3004
                    └──────────────────┬───────────────────┘
                                       │ MySQL :3306
                              RDS Aurora MySQL
                           (compatible MariaDB 10.11)
```

---

## Structure du projet

```
aws-ecommerce/
├── README.md                          # Ce fichier
├── docs/
│   └── GUIDE-DEPLOIEMENT-MANUEL.md   # Phase 1 - déploiement pas à pas
└── terraform/
    ├── environments/
    │   └── prod/
    │       ├── main.tf               # Point d'entrée - assemble tous les modules
    │       ├── variables.tf          # Déclaration des variables
    │       ├── terraform.tfvars      # Valeurs (sans secrets)
    │       └── outputs.tf            # Sorties (ALB DNS, ECR URLs, etc.)
    └── modules/
        ├── vpc/                      # VPC, subnets, NAT GW, route tables
        ├── sg/                       # Security Groups (ALB, frontend, EKS, RDS)
        ├── rds/                      # Aurora MySQL + Secrets Manager
        ├── ecr/                      # Repositories Docker (5 services)
        ├── eks/                      # Cluster EKS + node group
        ├── alb/                      # ALB public + Target Group + Listeners
        ├── frontend-ec2/             # Launch Template + ASG (Option A)
        ├── frontend-beanstalk/       # Elastic Beanstalk (Option B)
        └── frontend-ecs/             # ECS Fargate (Option C)
```

---

## Phase 1 - Déploiement Manuel

Voir le guide complet : [`docs/GUIDE-DEPLOIEMENT-MANUEL.md`](./docs/GUIDE-DEPLOIEMENT-MANUEL.md)

Le guide couvre dans l'ordre :
1. Configuration AWS CLI et outils
2. VPC, subnets, NAT Gateway, route tables
3. Security Groups (ALB → Frontend → EKS → RDS)
4. RDS Aurora (compatible MariaDB 10.11 - schéma identique)
5. ECR - migration des images de GHCR vers AWS
6. EKS - cluster + AWS Load Balancer Controller
7. Helm - déploiement des 4 microservices
8. Frontend en 3 variantes : EC2 ASG / Beanstalk / ECS Fargate
9. ALB public + CloudFront + Route 53
10. Vérification end-to-end

---

## Phase 2 - Terraform

### Prérequis

```bash
terraform version    # >= 1.6
aws --version        # >= 2.x
kubectl version      # >= 1.28
helm version         # >= 3.x
```

### Bootstrap du state Terraform

Avant le premier `terraform apply`, créer le bucket S3 et la table DynamoDB pour le state :

```bash
export AWS_REGION="eu-west-1"
export PROJECT="ecommerce"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Bucket state
aws s3 mb s3://$PROJECT-terraform-state --region $AWS_REGION
aws s3api put-bucket-versioning \
  --bucket $PROJECT-terraform-state \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption \
  --bucket $PROJECT-terraform-state \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# DynamoDB lock
aws dynamodb create-table \
  --table-name $PROJECT-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### Déploiement

```bash
cd terraform/environments/prod

# Initialiser
terraform init

# Passer les secrets via variables d'environnement (ne jamais committer)
export TF_VAR_db_password="votre_password_db"
export TF_VAR_jwt_secret="votre_jwt_secret_32chars_minimum"
export TF_VAR_certificate_arn="arn:aws:acm:eu-west-1:ACCOUNT:certificate/XXXXX"

# Choisir le mode frontend (ec2 | beanstalk | ecs)
export TF_VAR_frontend_mode="ec2"

# Planifier
terraform plan -out=tfplan

# Appliquer (~20min pour EKS)
terraform apply tfplan
```

### Switcher le mode frontend

Le paramètre `frontend_mode` active/désactive les trois modules frontend :

```bash
# Basculer vers Elastic Beanstalk
terraform apply -var="frontend_mode=beanstalk"

# Basculer vers ECS Fargate
terraform apply -var="frontend_mode=ecs"

# Revenir à EC2 ASG
terraform apply -var="frontend_mode=ec2"
```

### Mettre à jour les microservices

```bash
# Mettre à jour la version des images
terraform apply -var="microservices_image_tag=v3.4"
```

### Outputs importants

```bash
terraform output alb_dns          # URL du load balancer public
terraform output rds_endpoint     # Endpoint Aurora
terraform output eks_cluster_name # Nom du cluster EKS
terraform output ecr_urls         # URLs des repositories ECR
```

### Détruire l'environnement

```bash
terraform destroy
```

---

## Variables clés

| Variable | Description | Défaut |
|----------|-------------|--------|
| `aws_region` | Région AWS | eu-west-1 |
| `frontend_mode` | Mode frontend : `ec2`, `beanstalk`, `ecs` | ec2 |
| `microservices_image_tag` | Tag image microservices | v3.3 |
| `eks_node_instance_type` | Type d'instance EKS | t3.medium |
| `rds_instance_class` | Classe instance RDS | db.t3.medium |
| `db_password` | Mot de passe DB (sensible) | - |
| `jwt_secret` | Secret JWT (sensible) | - |
| `certificate_arn` | ARN certificat ACM HTTPS | - |

---

## Correspondances OCI → AWS

| OCI | AWS | Notes |
|-----|-----|-------|
| VCN | VPC | Régional |
| Compartment | AWS Account / Tags | Isolation logique |
| OCR | ECR | Registry Docker |
| OKE | EKS | Kubernetes managé |
| Autonomous DB | RDS Aurora | Compatible MariaDB |
| Load Balancer | ALB | Application Load Balancer |
| Security List | Security Group (stateful) | Différence : OCI = stateless par défaut |
| NSG | Security Group | 1:1 |

---

## Sécurité

- Les mots de passe ne transitent jamais en clair : `TF_VAR_*` ou Vault
- Les credentials DB sont stockés dans **AWS Secrets Manager**
- Chiffrement au repos : RDS + ECR + state S3
- Images ECR scannées à chaque push (Trivy intégré)
- Security Groups en chaîne : internet → ALB → Frontend → EKS → RDS

---

## Projets microservices

| Service | Port | Image GHCR / ECR |
|---------|------|-----------------|
| auth-service | 3001 | `yaraportfolio/auth-service:v3.3` |
| product-service | 3002 | `yaraportfolio/product-service:v3.3` |
| order-service | 3003 | `yaraportfolio/order-service:v3.3` |
| review-service | 3004 | `yaraportfolio/review-service:v3.3` |
| frontend | 80 | Build local → ECR |
