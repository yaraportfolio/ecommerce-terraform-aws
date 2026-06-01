# Guide Déploiement - Console AWS (Interface Web)
**Auteur :** Yara Mahi Mohamed | Portfolio DevOps & SRE  
**Prérequis :** Compte AWS actif, accès administrateur  
**Durée estimée :** 2h30 en suivant ce guide  
**Région cible :** `eu-west-1` (Irlande) - à sélectionner en haut à droite de la console

> 💡 **Philosophie de ce guide** : Chaque étape indique le chemin exact dans la console AWS (`Service → Sous-menu → Bouton`), ce que vous voyez à l'écran, et ce que vous devez saisir. Aucune commande CLI requise.

---

## Valeurs à utiliser tout au long du guide

Copiez ces valeurs dans un bloc-notes - vous en aurez besoin à chaque étape.

| Paramètre | Valeur |
|-----------|--------|
| Région | `eu-west-1` (Irlande) |
| Préfixe projet | `ecommerce` |
| CIDR VPC | `10.0.0.0/16` |
| Nom base de données | `ecommerce_db` |
| Utilisateur DB | `devops_user` |
| Port auth-service | `3001` |
| Port product-service | `3002` |
| Port order-service | `3003` |
| Port review-service | `3004` |

---

## Sommaire

1. [Vérifier la région](#1-vérifier-la-région)
2. [VPC - Réseau privé](#2-vpc--réseau-privé)
3. [Security Groups](#3-security-groups)
4. [RDS MySQL - Base de données](#4-rds-mysql--base-de-données)
5. [Secrets Manager - Stocker les credentials](#5-secrets-manager--stocker-les-credentials)
6. [ECR - Registry Docker](#6-ecr--registry-docker)
7. [EKS - Cluster Kubernetes](#7-eks--cluster-kubernetes)
8. [Frontend Option A - EC2 + Auto Scaling](#8-frontend-option-a--ec2--auto-scaling)
9. [Frontend Option B - Elastic Beanstalk](#9-frontend-option-b--elastic-beanstalk)
10. [Frontend Option C - ECS Fargate](#10-frontend-option-c--ecs-fargate)
11. [Application Load Balancer](#11-application-load-balancer)
12. [CloudFront](#12-cloudfront)
13. [Vérification finale dans la console](#13-vérification-finale-dans-la-console)

---

## 1. Vérifier la région

**Avant toute chose**, vérifiez que vous êtes dans la bonne région.

**Navigation :** Coin supérieur droit de la console AWS

**Ce que vous voyez :** Un menu déroulant affichant la région actuelle (ex. `US East (N. Virginia)`)

**Action :** Cliquer dessus → Sélectionner **Europe (Ireland) `eu-west-1`**

> ⚠️ Toutes les ressources que vous créez sont liées à une région. Si vous créez quelque chose dans la mauvaise région, il ne sera pas visible depuis les autres services.

---

## 2. VPC - Réseau privé

Le VPC est le réseau privé virtuel qui isole toute votre infrastructure. Pensez-y comme à votre datacenter privé dans le cloud.

### 2.1 Créer le VPC

**Navigation :** Barre de recherche en haut → taper `VPC` → cliquer **VPC**

**Sur la page VPC :**
1. Cliquer **Create VPC** (bouton orange en haut à droite)
2. Sélectionner **VPC and more** (pas "VPC only" - cette option crée tout en une fois)

**Remplir le formulaire :**

| Champ | Valeur |
|-------|--------|
| Name tag auto-generation | `ecommerce` |
| IPv4 CIDR block | `10.0.0.0/16` |
| Number of Availability Zones | **3** |
| Number of public subnets | **3** |
| Number of private subnets | **3** |
| NAT gateways | **Zonal - 1 per AZ** ou **Régional - nouveau** |
| VPC endpoints | **S3 Gateway** (réduit coûts NAT) |

**Ce que vous voyez :** Un aperçu visuel de votre architecture réseau s'affiche à droite.

3. Cliquer **Create VPC**
4. Attendre ~2 minutes que tout soit créé

**Résultat :** Vous verrez apparaître dans la liste VPC un élément nommé `ecommerce-vpc`.

### 2.2 Ajouter les tags Kubernetes sur les subnets

EKS a besoin de tags spécifiques sur les subnets pour créer automatiquement des Load Balancers.

**Navigation :** VPC → **Subnets** (menu de gauche)

**Pour chaque subnet public (3 subnets avec "public" dans le nom) :**
1. Cocher le subnet
2. Onglet **Tags** en bas de page
3. Cliquer **Manage tags**
4. Cliquer **Add new tag**
5. Ajouter : Clé = `kubernetes.io/role/elb` | Valeur = `1`
6. Cliquer **Save**

**Pour chaque subnet privé (3 subnets avec "private" dans le nom) :**
1. Même procédure
2. Ajouter : Clé = `kubernetes.io/role/internal-elb` | Valeur = `1`

> 💡 Ces tags permettent à EKS de savoir dans quels subnets créer les ALB internes (privés) et externes (publics) automatiquement.

### 2.3 Créer les subnets pour la base de données

Les subnets DB sont séparés des subnets privés EKS pour isoler la couche données.

**Navigation :** VPC → **Subnets** → **Create subnet**

**Subnet DB zone A :**

| Champ | Valeur |
|-------|--------|
| VPC ID | Sélectionner `ecommerce-vpc` |
| Subnet name | `ecommerce-db-a` |
| Availability Zone | `eu-west-1a` |
| IPv4 CIDR block | `10.0.48.0/20` |

Cliquer **Add new subnet** et remplir le second :

**Subnet DB zone B :**

| Champ | Valeur |
|-------|--------|
| Subnet name | `ecommerce-db-b` |
| Availability Zone | `eu-west-1b` |
| IPv4 CIDR block | `10.0.64.0/20` |

Cliquer **Add new subnet** et remplir le troisième :

**Subnet DB zone C :**

| Champ | Valeur |
|-------|--------|
| Subnet name | `ecommerce-db-c` |
| Availability Zone | `eu-west-1c` |
| IPv4 CIDR block | `10.0.80.0/20` |

Cliquer **Create subnet**.

**Associer à la route table privée :**  
Pour chaque subnet DB (3 au total), onglet **Route table** → **Edit route table association** → sélectionner la route table privée de la même AZ.

---

## 3. Security Groups

Les Security Groups sont des pare-feux virtuels. La règle d'or : chaque couche ne parle qu'à la couche suivante, en référençant d'autres SGs (pas des plages IP).

**Navigation :** VPC → **Security groups** (menu de gauche) → **Create security group**

### 3.1 SG - ALB public (internet → load balancer)

| Champ | Valeur |
|-------|--------|
| Security group name | `ecommerce-sg-alb` |
| Description | `ALB public - HTTP HTTPS depuis internet` |
| VPC | `ecommerce-vpc` |

**Inbound rules - cliquer Add rule pour chaque ligne :**

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| HTTP | TCP | 80 | `0.0.0.0/0` | HTTP depuis internet |
| HTTPS | TCP | 443 | `0.0.0.0/0` | HTTPS depuis internet |

**Outbound rules :** Laisser la règle par défaut (All traffic → 0.0.0.0/0)

Cliquer **Create security group** → noter l'ID (ex. `sg-0abc123456`)

---

### 3.2 SG - Frontend (ALB → instances frontend)

**Create security group :**

| Champ | Valeur |
|-------|--------|
| Security group name | `ecommerce-sg-frontend` |
| Description | `Frontend - trafic depuis ALB uniquement` |
| VPC | `ecommerce-vpc` |

**Inbound rules :**

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| HTTP | TCP | 80 | `ecommerce-sg-alb` ← **sélectionner le SG, pas un CIDR** | Trafic depuis l'ALB |

> 💡 **Astuce console :** Dans le champ Source, tapez `sg-` et une liste déroulante affiche vos SGs. Sélectionner `ecommerce-sg-alb`. C'est la chaîne de SGs - plus robuste qu'une IP.

Cliquer **Create security group**

---

### 3.3 SG - EKS (frontend → microservices)

**Create security group :**

| Champ | Valeur |
|-------|--------|
| Security group name | `ecommerce-sg-eks` |
| Description | `EKS nodes - ports microservices` |
| VPC | `ecommerce-vpc` |

**Inbound rules - 5 règles à ajouter :**

| Type | Protocol | Port range | Source |
|------|----------|-----------|--------|
| Custom TCP | TCP | `3001` | `ecommerce-sg-frontend` |
| Custom TCP | TCP | `3002` | `ecommerce-sg-frontend` |
| Custom TCP | TCP | `3003` | `ecommerce-sg-frontend` |
| Custom TCP | TCP | `3004` | `ecommerce-sg-frontend` |
| All traffic | All | All | `ecommerce-sg-eks` ← **le SG lui-même** (communication intra-cluster) |

> 💡 La règle "self" permet aux pods Kubernetes de communiquer entre eux sans restriction.

Cliquer **Create security group**

---

### 3.4 SG - RDS (EKS → base de données)

**Create security group :**

| Champ | Valeur |
|-------|--------|
| Security group name | `ecommerce-sg-rds` |
| Description | `RDS MySQL - accès depuis EKS uniquement` |
| VPC | `ecommerce-vpc` |

**Inbound rules :**

| Type | Protocol | Port | Source |
|------|----------|------|--------|
| MySQL | TCP | `3306` | `ecommerce-sg-eks` |

Cliquer **Create security group**

---

## 4. RDS MySQL - Base de données

MySQL 8.0 est compatible MariaDB 10.11 - votre schéma `ecommerce_db.sql` et vos drivers `mysql2` fonctionnent sans modification.

> 💡 **Pourquoi MySQL et pas Aurora ?** Aurora n'est pas gratuit sur le Free Tier. MySQL standard est parfait pour un portfolio et coûte ~$20/mois.

### 4.1 Créer l'instance MySQL

**Navigation :** RDS → **Databases** → **Create database**

> ⚠️ **Note :** MySQL standard ne nécessite pas de Subnet Group si tu mets "Public access = Yes" pour le portfolio. Pour la sécurité, tu peux l'ignorer cette étape et utiliser le VPC par défaut.

Ou si tu veux un Subnet Group :

| Champ | Valeur |
|-------|--------|
| Name | `ecommerce-db-subnet-group` |
| Description | `Subnets pour RDS MySQL ecommerce` |
| VPC | `ecommerce-vpc` |
| Availability Zones | Sélectionner `eu-west-1a`, `eu-west-1b` ET `eu-west-1c` |
| Subnets | Sélectionner `ecommerce-db-a`, `ecommerce-db-b` ET `ecommerce-db-c` |

---

### 4.2 Créer l'instance MySQL

**Navigation :** RDS → **Databases** → **Create database**

**Database creation method :**

Deux options possibles (résultat identique, niveau de détail différent) :

| Option | Quand l'utiliser |
|--------|-----------------|
| **Easy create** | Vous voulez une création rapide avec defaults AWS |
| **Full configuration** | ✅ **Recommandé** - Contrôle total des paramètres |

**Pour ce guide, nous utilisons "Full configuration"** (plus de contrôle).

---

**Engine options :**
- Engine type : ✅ **MySQL**
- Engine version : **MySQL 8.4.8** (ou plus récent, 8.0.37 minimum)

> 💡 MySQL 8.0+ est compatible MariaDB 10.11 - vos drivers `mysql2` et schémas fonctionnent sans modification.

**Templates :**
- ✅ **Dev/Test** ou **Production** (selon ton besoin)

---

**Settings - Credentials :**

| Champ | Valeur |
|-------|--------|
| DB instance identifier | `ecommerce-mysql` |
| Master username | `devops_user` |
| Master password | `VotreMotDePasse32CaracMin!` |
| Confirm password | (répéter) |
| Credentials management | **Self managed** |

---

**Instance configuration :**

| Champ | Valeur |
|-------|--------|
| DB instance class | **Burstable classes (t4g)** → `db.t4g.micro` ← **Free Tier eligible** |
| Storage type | **General Purpose SSD (gp2)** |
| Allocated storage | **20 GiB** |

---

**Availability & durability :**

| Champ | Valeur |
|-------|--------|
| Deployment options | **Single-AZ DB instance** |
| Multi-AZ | **No** (coûteux, optionnel pour portfolio) |

---

**Connectivity :**

| Champ | Valeur |
|-------|--------|
| Virtual private cloud (VPC) | `ecommerce-vpc` |
| DB subnet group | `ecommerce-db-subnet-group` |
| Public access | **No** ← (Si Subnet Group utilisé) |
| VPC security group (firewall) | **Choose existing** → `ecommerce-sg-rds` |
| Availability Zone | **No preference** |

> ⚠️ **Règle de Public access :**
> - Si tu utilises **Subnet Group** (réseau privé) → Public access = **No**
> - Si tu n'utilises PAS Subnet Group → Public access = **Yes**
>
> Nous utilisons Subnet Group, donc **Public access = No**.

---

**Additional configuration :**

| Champ | Valeur |
|-------|--------|
| Initial database name | `ecommerce_db` |
| DB port | `3306` |
| Parameter group | `default:mysql8.4` |
| Option group | `default:mysql-8-4` |
| Backup retention period | **7 days** |
| Database encryption | ✅ **Enable encryption** (Coché) |
| Monitoring | **Database Insights - Standard** |

Cliquer **Create database** → Attendre **~5-10 minutes**

**Récupérer l'endpoint :**  
Une fois le statut `Available`, cliquer sur `ecommerce-mysql` → Section **Connectivity & security** → Copier l'**Endpoint** (ex. `ecommerce-mysql.c9akciq32.eu-west-1.rds.amazonaws.com`).

---

### 4.3 Importer le schéma

Pour importer `ecommerce_db.sql`, vous avez besoin d'un accès réseau à la base. Deux approches :

---

**Option A - EC2 Bastion temporaire (avec SSL - Recommandé pour portfolio)**

1. **Lancer une EC2 `t3.micro` dans un subnet public**
   - Navigation : EC2 → Launch instances
   - AMI : Amazon Linux 2
   - Security Group : `ecommerce-sg-eks`
   - Attendre le statut "Running"

2. **Télécharger le bundle SSL RDS**
   
   Depuis votre **machine locale** (pas l'EC2) :
   ```bash
   # Créer un dossier pour le certificat
   mkdir -p ~/rds-certs
   cd ~/rds-certs
   
   # Télécharger le bundle de certificats RDS (valide globalement)
   curl https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o global-bundle.pem
   ```

3. **Se connecter à l'EC2 et préparer l'import**
   
   Navigation : EC2 → Instances → Sélectionner instance → Connect → EC2 Instance Connect (onglet)
   
   Dans le terminal web de l'EC2 :
   ```bash
   # Installer le client MySQL
   sudo dnf install -y mariadb105
   
   # Créer le dossier pour le certificat
   mkdir -p ~/rds-certs
   ```

4. **Importer le schéma avec SSL (version sécurisée)**
   
   Dans le terminal de l'EC2 :
   ```bash
   cd
   mysql -h ecommerce-mysql.c9akciq32.eu-west-1.rds.amazonaws.com \
         -P 3306 \
         -u devops_user \
         -p \
         --ssl-verify-server-cert \
         --ssl-ca=~/rds-certs/global-bundle.pem \
         ecommerce_db < ecommerce_db.sql
   ```
   
   (Remplace l'endpoint `ecommerce-mysql.c9akciq32.eu-west-1.rds.amazonaws.com` par celui que tu as copié)

5. **Arrêter l'EC2 bastion après l'import**
   
   Navigation : EC2 → Instances → Stop (ne pas Delete pour garder une trace)

---

**Option B - Version simple (sans SSL - rapide)**

Si tu veux juste importer sans complexité SSL :

```bash
mysql -h ecommerce-mysql.c9akciq32.eu-west-1.rds.amazonaws.com \
      -P 3306 \
      -u devops_user \
      -p \
      ecommerce_db < ecommerce_db.sql
```

> ℹ️ Même effet, juste sans vérification SSL du certificat. Pour un portfolio, **Option A avec SSL est plus professionnelle**.

---

**Option C - AWS Systems Manager Session Manager** (alternative sans EC2)

Plus complexe à configurer mais pas d'instance EC2 à gérer. Contact ton DevOps interne pour l'accès IAM.

---

## 5. Secrets Manager - Stocker les credentials

Plutôt que de mettre les mots de passe dans des variables d'environnement en clair, on les stocke dans Secrets Manager.

**Navigation :** Barre de recherche → `Secrets Manager` → **Secrets Manager**

**Cliquer Store a new secret**

### Secret 1 - Credentials base de données

**Step 1 - Secret type :**
- ✅ **Credentials for Amazon RDS database**
- User name : `devops_user`
- Password : `VotreMotDePasse32CaracMin!`
- Database : sélectionner `ecommerce-mysql`

**Step 2 - Secret name :**
- Secret name : `ecommerce/db/credentials`
- Description : `Credentials RDS MySQL ecommerce`

**Step 3 - Rotation :** Laisser désactivé pour l'instant

Cliquer **Store**

---

---

## 📝 Résumé des Registries (Stratégie Portfolio)

**Frontend :**
- Registry: **ECR** (Elastic Container Registry - AWS)
- Accès: **Privé** (authentification AWS requise)
- Deployment: EC2, Beanstalk, ou ECS

**Microservices (4 services) :**
- Registry: **GHCR** (GitHub Container Registry)
- Accès: **Public** (pas d'authentification requise)
- Services: auth-service, product-service, order-service, review-service
- Repository: `ghcr.io/yaraportfolio/{service-name}`

> 💡 Cette stratégie permet une gestion simple du portfolio : microservices publics sur GitHub (CI/CD GitHub Actions natif), frontend privé sur AWS (meilleures performances de déploiement).

---

### Secret 2 - JWT Secret

**Cliquer Store a new secret**

**Step 1 - Secret type :**
- ✅ **Other type of secret**
- Sélectionner **Plaintext**
- Coller votre secret JWT (minimum 32 caractères) :
```
VotreJwtSecretSuperSécuriséMin32Chars!
```

**Step 2 - Secret name :**
- Secret name : `ecommerce/jwt/secret`

Cliquer **Store**

> 💡 Tous vos microservices (auth, product, order, review) partagent le même `JWT_SECRET`. Centraliser ici évite les désynchronisations.

---

## 6. ECR - Registry Docker

ECR hébergera les images Docker du frontend. Les microservices resteront sur GitHub Container Registry (GHCR - public).

**Navigation :** Barre de recherche → `ECR` → **Elastic Container Registry**

### 6.1 Créer le repository Frontend

**Cliquer Create repository** - créer 1 seul repository :

**Repository - Frontend :**

| Champ | Valeur |
|-------|--------|
| Visibility settings | **Private** |
| Repository name | `ecommerce/frontend` |
| Tag immutability | **Mutable** |
| Scan on push | ✅ **Enabled** |
| Encryption | **AES-256** |

Cliquer **Create repository**

**Ce que vous voyez :** 1 repository dans la liste avec son URI complet (ex. `123456789.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend`)

---

### 6.2 Microservices sur GHCR (public)

Les 4 microservices restent sur GitHub Container Registry (GHCR) :
- `ghcr.io/yaraportfolio/auth-service:latest`
- `ghcr.io/yaraportfolio/product-service:latest`
- `ghcr.io/yaraportfolio/order-service:latest`
- `ghcr.io/yaraportfolio/review-service:latest`

Pas besoin de les créer dans ECR (déjà disponibles publiquement sur GHCR).

---

## 7. EKS - Cluster Kubernetes

EKS crée et gère le control plane Kubernetes. Vous gérez les worker nodes via des Node Groups.

### 7.1 Créer le cluster EKS

**Navigation :** Barre de recherche → `EKS` → **Elastic Kubernetes Service**

**Cliquer Add cluster → Create**

**Configuration options :**

Deux choix s'offrent à vous :

| Option | Recommandé | Raison |
|--------|-----------|--------|
| **Quick configuration (with EKS Auto Mode)** | ✅ **OUI - Choisir ceci** | Automatisé, defaults production-grade, idéal pour portfolio |
| Custom configuration | Non | Plus complexe, plus de contrôle (optionnel) |

> 💡 **Pour un portfolio, "Quick configuration" est plus simple** : EKS Auto Mode automatise la création des nodes et de la provisioning.

**Cliquer "Quick configuration (with EKS Auto Mode)"**

---

**Step 1 - Configure cluster :**

| Champ | Valeur |
|-------|--------|
| Name | `ecommerce-cluster` |
| Kubernetes version | **1.29** (ou plus récent) |

> 💡 Quick configuration utilise les defaults recommandés par AWS. Pas besoin de configurer le Cluster service role manuellement.

**Step 2 - Specify networking :**

| Champ | Valeur |
|-------|--------|
| VPC | `ecommerce-vpc` |
| Subnets | Sélectionner les **3 subnets EKS privés** (1 par AZ) |
| Security groups | `ecommerce-sg-eks` |
| Cluster endpoint access | **Public and private** |

**Step 3 - Configure observability :** Laisser par défaut

**Step 4 - Select add-ons :**
- ✅ CoreDNS
- ✅ kube-proxy
- ✅ Amazon VPC CNI
- ✅ Amazon EBS CSI Driver
- ✅ Metrics Server (requis pour HPA/autoscaling)
- ✅ AWS Secrets and Configuration Provider (optionnel - seulement si vous utilisez AWS Secrets Manager)

**Step 5 - Configure selected add-ons settings :** Laisser les versions par défaut

**Step 6 - Review :** Vérifier → **Create**

Attendre **~12 minutes** que le statut passe à `Active`.

---

### 7.2 Node Pools (Gérés automatiquement avec EKS Auto Mode)

> ℹ️ **Avec "Quick configuration (with EKS Auto Mode)", AWS gère TOUS les nodes automatiquement.**
>
> **Vous n'avez RIEN à faire ici !** Les node pools sont visibles dans la console mais gérés 100% par AWS.
> - Scaling automatique ✅
> - Santé des nodes vérifiée ✅
> - Mises à jour gérées ✅
> - Pas de Node Groups à créer manuellement

**Vérification :** EKS → `ecommerce-cluster` → Onglet **Compute**
- Vous verrez 2 node pools pré-créés : `general-purpose` et `system`
- Vous verrez N nodes Ready (créés automatiquement)
- **C'est tout ce qu'il faut ! Passez à l'étape 7.3.**

> 💡 **Advanced (optionnel)** : Si vous avez besoin de configurations très spécifiques, vous pouvez créer des Node Groups manuels via **Add node group**, mais ce n'est pas recommandé pour un portfolio simple.

---

### 7.3 Configurer kubectl

**Option A : Via AWS Console (le plus simple) ✅**

EKS → `ecommerce-cluster` → Bouton **"Connect"** (en haut à droite)

AWS CloudShell s'ouvre automatiquement avec kubectl configuré.

```bash
# La commande s'affiche automatiquement
source kubectl-connect ecommerce-cluster

# Vérifier les nodes
kubectl get nodes
# Les nodes doivent apparaître avec le statut Ready
# (nombre variable avec EKS Auto Mode - 2, 3, 4+ selon la charge)
```

---

**Option B : Via votre machine locale (si vous préférez)**

Depuis votre terminal local (avec AWS CLI + kubectl installés) :

```bash
aws eks update-kubeconfig --region eu-west-1 --name ecommerce-cluster
kubectl get nodes
```

---

### 7.4 Déployer les microservices via Helm

#### Déploiement EKS (AWS Secrets Manager + CSI Driver) ✅

```bash
# Créer le namespace
kubectl create namespace ecommerce

# Déployer via Helm (AVEC AWS Secrets Manager)
# Note: Remplacer ROLE_ARN par l'ARN de votre rôle IAM créé précédemment
helm install ecommerce-microservices . \
  --namespace ecommerce \
  --set image.registryType="ghcr" \
  --set image.ghcr.registry="ghcr.io" \
  --set image.ghcr.owner="yaraportfolio" \
  --set awsSecretsManager.enabled=true \
  --set awsSecretsManager.region=eu-west-1 \
  --set awsSecretsManager.iamRoleArn="arn:aws:iam::020379956170:role/ecommerce-eks-secrets-role"
```

**Prérequis :**
- ✅ ASCP add-on installé sur le cluster EKS
- ✅ Rôle IAM `ecommerce-eks-secrets-role` créé avec IRSA
- ✅ 2 secrets créés dans AWS Secrets Manager : `ecommerce/db/credentials` et `ecommerce/jwt/secret`

---

**Vérifier dans la console EKS :**  
EKS → `ecommerce-cluster` → **Resources** → **Pods** → Namespace `ecommerce`  
Vous devez voir 8 pods (2 réplicas × 4 services) avec le statut `Running`.

**Vérifier les ressources CSI :**
```bash
kubectl get secretproviderclass -n ecommerce
kubectl get serviceaccount ecommerce-sa -n ecommerce
kubectl get secret microservices-secret -n ecommerce  # auto-créé par CSI
```

---

## 8. Frontend Option A - EC2 + Auto Scaling

Cette option déploie le frontend NGINX + React sur des VMs EC2 classiques avec autoscaling.

### 8.1 Créer un rôle IAM pour les instances EC2

**Navigation :** Barre de recherche → `IAM` → **IAM**

**Roles → Create role**

| Champ | Valeur |
|-------|--------|
| Trusted entity type | **AWS service** |
| Use case | **EC2** |

Cliquer **Next** → Rechercher et ajouter ces policies :
- `AmazonEC2ContainerRegistryReadOnly` ← pour puller les images ECR
- `AmazonSSMManagedInstanceCore` ← pour Session Manager (accès SSH sans clé)

**Role name :** `ecommerce-frontend-ec2-role`

Cliquer **Create role**

**Créer l'instance profile :**  
IAM → Roles → `ecommerce-frontend-ec2-role` → l'instance profile est créé automatiquement avec le même nom.

---

### 8.2 Créer le Launch Template

**Navigation :** EC2 → **Launch Templates** → **Create launch template**

| Champ | Valeur |
|-------|--------|
| Launch template name | `ecommerce-frontend-lt` |
| Template version description | `v1 - NGINX + React ECR` |
| ✅ Provide guidance to help me set up a template | Coché |

**Application and OS Images :**
- Cliquer **Quick Start** → **Amazon Linux 2023 AMI**
- Architecture : `x86_64`

**Instance type :** `t3.medium`

**Network settings :**
- Security groups : `ecommerce-sg-frontend`

**Advanced details :**
- IAM instance profile : `ecommerce-frontend-ec2-role`
- User data : Cliquer la zone de texte et coller le script suivant

```bash
#!/bin/bash
# Installer Docker
yum update -y
yum install docker -y
service docker start
usermod -a -G docker ec2-user
systemctl enable docker

# Récupérer l'Account ID
ACCOUNT_ID=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ \
  | head -1 | cut -d'/' -f3 2>/dev/null || \
  aws sts get-caller-identity --query Account --output text)

# Login ECR
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS \
  --password-stdin ${ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com

# URL de l'ALB interne EKS (à remplacer après création EKS)
BACKEND_URL="http://INTERNAL_ALB_DNS_ICI"

# Lancer le frontend
docker run -d \
  --name ecommerce-frontend \
  -p 80:80 \
  -e BACKEND_URL=$BACKEND_URL \
  -e BACKEND_HOST="api.ecommerce.local" \
  --restart always \
  ${ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend:latest
```

> ⚠️ Remplacer `INTERNAL_ALB_DNS_ICI` par l'endpoint de l'ALB interne EKS récupéré après `kubectl get ingress -n ecommerce`.

Cliquer **Create launch template**

---

### 8.3 Créer l'Auto Scaling Group

**Navigation :** EC2 → **Auto Scaling Groups** → **Create Auto Scaling group**

**Step 1 - Choose launch template :**

| Champ | Valeur |
|-------|--------|
| Auto Scaling group name | `ecommerce-frontend-asg` |
| Launch template | `ecommerce-frontend-lt` |
| Version | `Latest` |

**Step 2 - Choose instance launch options :**

| Champ | Valeur |
|-------|--------|
| VPC | `ecommerce-vpc` |
| Availability Zones and subnets | Sélectionner les **3 subnets publics** |

**Step 3 - Configure advanced options :**
- ✅ **Attach to an existing load balancer**
- Target groups : sélectionner `ecommerce-tg-frontend` (créé à l'étape 11)

> ℹ️ Si le Target Group n'existe pas encore, cocher **No load balancer** et revenir après l'étape 11.

- Health check grace period : `120` secondes

**Step 4 - Configure group size and scaling :**

| Champ | Valeur |
|-------|--------|
| Desired capacity | `2` |
| Min desired capacity | `2` |
| Max desired capacity | `6` |

**Automatic scaling :**
- ✅ **Target tracking scaling policy**
- Metric type : **Average CPU utilization**
- Target value : `70`

**Step 5 - Add notifications :** Optionnel

**Step 6 - Add tags :**

| Key | Value |
|-----|-------|
| Name | `ecommerce-frontend` |
| Env | `prod` |

Cliquer **Create Auto Scaling group**

---

## 9. Frontend Option B - Elastic Beanstalk

Beanstalk gère tout automatiquement : EC2, ALB, autoscaling. Idéal pour comprendre le modèle PaaS.

**Navigation :** Barre de recherche → `Elastic Beanstalk` → **Elastic Beanstalk**

**Cliquer Create application**

### 9.1 Configurer l'application

**Step 1 - Configure environment :**

| Champ | Valeur |
|-------|--------|
| Environment tier | **Web server environment** |
| Application name | `ecommerce-frontend` |
| Environment name | `ecommerce-frontend-prod` |
| Platform | **Docker** |
| Platform branch | **Docker running on 64bit Amazon Linux 2** |
| Application code | **Upload your code** |

**Uploader le fichier `Dockerrun.aws.json` :**

Créer ce fichier sur votre machine et l'uploader :

```json
{
  "AWSEBDockerrunVersion": "1",
  "Image": {
    "Name": "VOTRE_ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend:latest",
    "Update": "true"
  },
  "Ports": [
    { "ContainerPort": "80" }
  ],
  "Environment": [
    { "Name": "BACKEND_URL", "Value": "http://INTERNAL_ALB_DNS" },
    { "Name": "BACKEND_HOST", "Value": "api.ecommerce.local" }
  ]
}
```

**Step 2 - Configure service access :**
- Service role : **Create and use new service role**
- EC2 instance profile : `ecommerce-frontend-ec2-role`

**Step 3 - Set up networking, database, and tags :**

| Champ | Valeur |
|-------|--------|
| VPC | `ecommerce-vpc` |
| Public IP address | ✅ Activated |
| Instance subnets | Sélectionner les subnets publics |
| Instance security groups | `ecommerce-sg-frontend` |

**Step 4 - Configure instance traffic and scaling :**

| Champ | Valeur |
|-------|--------|
| Root volume type | `gp3` |
| Root volume size | `20` GB |
| Min instances | `2` |
| Max instances | `6` |
| Instance type | `t3.medium` |
| Scaling triggers | CPU utilization : `70%` |

**Step 5 - Configure updates, monitoring, and logging :**
- Deployment policy : **Rolling**
- Batch size : `50%`
- ✅ Health reporting : Enhanced

Cliquer **Submit** → Attendre ~5 minutes

**URL de l'environnement :** Visible dans la console Beanstalk sous la forme `ecommerce-frontend-prod.eba-xxx.eu-west-1.elasticbeanstalk.com`

---

## 10. Frontend Option C - ECS Fargate

ECS Fargate exécute vos conteneurs sans gérer de serveurs. AWS provisionne les ressources de calcul à la demande.

### 10.1 Créer le cluster ECS

**Navigation :** Barre de recherche → `ECS` → **Elastic Container Service**

**Cliquer Create cluster**

| Champ | Valeur |
|-------|--------|
| Cluster name | `ecommerce-frontend-cluster` |
| Infrastructure | ✅ **AWS Fargate (serverless)** |

Cliquer **Create**

---

### 10.2 Créer le Task Definition

**Navigation :** ECS → **Task definitions** → **Create new task definition**

**Step 1 - Task definition configuration :**

| Champ | Valeur |
|-------|--------|
| Task definition family | `ecommerce-frontend` |
| Launch type | **AWS Fargate** |
| Operating system/Architecture | **Linux/X86_64** |
| Task size - CPU | `.25 vCPU` |
| Task size - Memory | `0.5 GB` |
| Task role | `ecommerce-frontend-ec2-role` |
| Task execution role | **Create new role** |

**Container :**

| Champ | Valeur |
|-------|--------|
| Name | `frontend` |
| Image URI | `ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend:latest` |
| Container port | `80` |
| Protocol | `TCP` |

**Environment variables (cliquer Add environment variable pour chaque) :**

| Key | Value type | Value |
|-----|-----------|-------|
| `BACKEND_URL` | Value | `http://INTERNAL_ALB_DNS` |
| `BACKEND_HOST` | Value | `api.ecommerce.local` |

**Log collection :**
- ✅ **Use log collection**
- Log group : `/ecs/ecommerce-frontend`

Cliquer **Create**

---

### 10.3 Créer le Service ECS

**Navigation :** ECS → `ecommerce-frontend-cluster` → Onglet **Services** → **Deploy**

| Champ | Valeur |
|-------|--------|
| Compute options | **Launch type** → **FARGATE** |
| Application type | **Service** |
| Family | `ecommerce-frontend` |
| Revision | **LATEST** |
| Service name | `ecommerce-frontend-svc` |
| Desired tasks | `2` |

**Networking :**

| Champ | Valeur |
|-------|--------|
| VPC | `ecommerce-vpc` |
| Subnets | Subnets publics |
| Security group | `ecommerce-sg-frontend` |
| Public IP | **Turned on** |

**Load balancing :**
- ✅ **Use an existing load balancer**
- Load balancer : `ecommerce-alb-pub` (créé à l'étape 11)
- Listener : **Use an existing listener** → `443 : HTTPS`
- Target group : `ecommerce-tg-frontend`

Cliquer **Deploy**

---

## 11. Application Load Balancer

L'ALB est le point d'entrée unique pour le trafic internet. Il distribue vers les instances frontend.

### 11.1 Créer le Target Group

**Navigation :** EC2 → **Target Groups** (menu de gauche, section Load Balancing) → **Create target group**

**Basic configuration :**

| Champ | Valeur |
|-------|--------|
| Target type | **Instances** (pour EC2/Beanstalk) ou **IP** (pour ECS Fargate) |
| Target group name | `ecommerce-tg-frontend` |
| Protocol | **HTTP** |
| Port | `80` |
| VPC | `ecommerce-vpc` |

**Health checks :**

| Champ | Valeur |
|-------|--------|
| Health check protocol | HTTP |
| Health check path | `/` |
| Healthy threshold | `2` |
| Unhealthy threshold | `3` |
| Timeout | `5` seconds |
| Interval | `30` seconds |

Cliquer **Next** → **Create target group**

---

### 11.2 Créer l'ALB

**Navigation :** EC2 → **Load Balancers** → **Create load balancer**

Sélectionner **Application Load Balancer** → **Create**

**Basic configuration :**

| Champ | Valeur |
|-------|--------|
| Load balancer name | `ecommerce-alb-pub` |
| Scheme | **Internet-facing** |
| IP address type | **IPv4** |

**Network mapping :**
- VPC : `ecommerce-vpc`
- Mappings : Cocher les **3 AZ** et sélectionner les **subnets publics** correspondants

**Security groups :**
- Retirer le SG par défaut → Ajouter `ecommerce-sg-alb`

**Listeners and routing :**

**Listener 1 - HTTP:80 (redirection vers HTTPS) :**
- Protocol : `HTTP` | Port : `80`
- Default action : **Redirect to HTTPS**
- Port : `443` | Status code : `301`

**Listener 2 - HTTPS:443 :**
- Protocol : `HTTPS` | Port : `443`
- Default action : **Forward to** `ecommerce-tg-frontend`
- Security policy : `ELBSecurityPolicy-TLS13-1-2-2021-06`
- Certificate : Sélectionner votre certificat ACM (voir encadré ci-dessous)

> **Obtenir un certificat ACM :**  
> Barre de recherche → `Certificate Manager` → **Request certificate**  
> → **Request a public certificate** → Entrer votre domaine (ex. `ecommerce.votredomaine.com`)  
> → Validation DNS → Suivre les instructions pour ajouter l'enregistrement CNAME dans votre DNS  
> → Attendre ~5 minutes que le certificat soit émis

Cliquer **Create load balancer**

**Récupérer le DNS de l'ALB :**  
Dans la liste des Load Balancers → `ecommerce-alb-pub` → Colonne **DNS name**  
Ex. `ecommerce-alb-pub-123456.eu-west-1.elb.amazonaws.com`

---

### 11.3 Vérifier le routage

**Navigation :** EC2 → **Target Groups** → `ecommerce-tg-frontend` → Onglet **Targets**

Vous devez voir vos instances (EC2, ECS tasks) avec le statut **healthy**.  
Si le statut est **unhealthy** → vérifier que le SG Frontend autorise le port 80 depuis le SG ALB.

---

## 12. CloudFront

CloudFront met en cache le frontend globalement (CDN mondial) et ajoute une couche de sécurité WAF.

**Navigation :** Barre de recherche → `CloudFront` → **CloudFront**

> ⚠️ CloudFront est un service **global** (pas régional) - la console affiche toujours "Global" dans le sélecteur de région. C'est normal.

**Cliquer Create a CloudFront distribution**

### Origin

| Champ | Valeur |
|-------|--------|
| Origin domain | Coller le DNS de l'ALB : `ecommerce-alb-pub-xxx.eu-west-1.elb.amazonaws.com` |
| Protocol | **HTTPS only** |
| HTTPS port | `443` |
| Origin path | Laisser vide |
| Name | `ALB-ecommerce` |

### Default cache behavior

| Champ | Valeur |
|-------|--------|
| Viewer protocol policy | **Redirect HTTP to HTTPS** |
| Allowed HTTP methods | **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE** (API + frontend) |
| Cache policy | **CachingDisabled** pour les routes `/api/*` |
| Origin request policy | **AllViewer** |
| Compress objects automatically | ✅ Yes |

### Additional cache behaviors - pour l'API

Cliquer **Add behavior** :

| Champ | Valeur |
|-------|--------|
| Path pattern | `/api/*` |
| Cache policy | **CachingDisabled** |
| Origin request policy | **AllViewer** |

### Settings

| Champ | Valeur |
|-------|--------|
| Price class | **Use only North America and Europe** |
| Alternate domain name (CNAME) | `ecommerce.votredomaine.com` |
| Custom SSL certificate | Sélectionner votre certificat ACM |
| Default root object | `index.html` |

Cliquer **Create distribution** → Attendre **~10 minutes** (déploiement mondial)

**Récupérer le domaine CloudFront :** Visible dans la liste, ex. `d1234abcd.cloudfront.net`

---

### Route 53 - Pointer votre domaine

**Navigation :** Barre de recherche → `Route 53` → **Route 53**

**Hosted zones** → sélectionner votre zone → **Create record**

| Champ | Valeur |
|-------|--------|
| Record name | `ecommerce` |
| Record type | **A** |
| ✅ Alias | Coché |
| Route traffic to | **Alias to CloudFront distribution** |
| Distribution | Sélectionner votre distribution |

Cliquer **Create records**

---

## 13. Vérification finale dans la console

Une fois tout déployé, voici comment vérifier que chaque couche fonctionne depuis la console AWS.

### 13.1 VPC - Vérifier la connectivité réseau

**Navigation :** VPC → **Reachability Analyzer** → **Create and analyze path**

| Champ | Valeur |
|-------|--------|
| Source type | Load balancer |
| Source | `ecommerce-alb-pub` |
| Destination type | Instance |
| Destination | Une instance frontend |

Cliquer **Run** → Le résultat indique si le chemin réseau est accessible.

---

### 13.2 RDS MySQL - Vérifier la connexion

**Navigation :** RDS → **Databases** → `ecommerce-mysql`

**Ce que vous vérifiez :**
- Status : `Available` ✅
- Onglet **Monitoring** : CPU utilization, Database connections
- Onglet **Connectivity & security** : l'endpoint writer est bien affiché
- Onglet **Configuration** : VPC et SG correspondent à `ecommerce-sg-rds`

---

### 13.3 EKS - Vérifier les pods

**Navigation :** EKS → **Clusters** → `ecommerce-cluster` → **Resources** → **Pods**

- Namespace : sélectionner `ecommerce`
- Vous devez voir **8 pods** (2 × auth, product, order, review) en statut `Running`

**Vérifier les logs d'un pod :**  
Cliquer sur un pod → Onglet **Logs** → Sélectionner le container → Voir les logs en temps réel

---

### 13.4 ALB - Vérifier les targets

**Navigation :** EC2 → **Target Groups** → `ecommerce-tg-frontend` → Onglet **Targets**

- Toutes les instances/tasks doivent être en statut `healthy`
- Si `unhealthy` : vérifier les Security Groups et le Health Check path

**Tester l'ALB directement :**  
EC2 → **Load Balancers** → `ecommerce-alb-pub` → Copier le **DNS name** → Ouvrir dans un navigateur

---

### 13.5 CloudWatch - Monitorer en temps réel

**Navigation :** Barre de recherche → `CloudWatch` → **CloudWatch**

**Dashboards → Create dashboard** → `ecommerce-monitoring`

**Ajouter les widgets suivants :**

**Widget 1 - RDS MySQL connexions :**
- Type : Line
- Metrics : RDS → Per-Database Metrics → `ecommerce-mysql` → DatabaseConnections

**Widget 2 - ALB requêtes :**
- Type : Number
- Metrics : ApplicationELB → Per AppELB Metrics → `ecommerce-alb-pub` → RequestCount

**Widget 3 - EKS pods :**
- Type : Line
- Metrics : ContainerInsights → Cluster → `ecommerce-cluster` → pod_cpu_utilization

---

### 13.6 Test end-to-end depuis le navigateur

1. Ouvrir `https://ecommerce.votredomaine.com` → Page d'accueil du shop ✅
2. Aller dans **Produits** → La liste s'affiche (product-service) ✅
3. Cliquer **Connexion** → Se connecter avec `admin@ecommerce.com` / `admin123` ✅
4. Ajouter un produit au panier → Passer une commande ✅
5. Dashboard Admin → Gérer les commandes, produits, avis ✅

---

## Récapitulatif des ressources créées

| Service AWS | Ressource | Nom |
|-------------|-----------|-----|
| VPC | Réseau privé | `ecommerce-vpc` |
| VPC | Subnets publics | `ecommerce-pub-a/b/c` |
| VPC | Subnets privés | `ecommerce-priv-a/b` |
| VPC | Subnets DB | `ecommerce-db-a/b` |
| VPC | NAT Gateway | `ecommerce-nat-a/b` |
| EC2 | Security Groups | `sg-alb`, `sg-frontend`, `sg-eks`, `sg-rds` |
| RDS MySQL | Instance | `ecommerce-mysql` |
| Secrets Manager | Secrets | `ecommerce/db/credentials`, `ecommerce/jwt/secret` |
| ECR | Repositories | 5 repos (`auth`, `product`, `order`, `review`, `frontend`) |
| EKS | Cluster K8s | `ecommerce-cluster` |
| EKS | Node Group | `ecommerce-nodes` (2-6 × t3.medium) |
| Helm | Microservices | `ecommerce-microservices` (4 services, 8 pods) |
| EC2 | Launch Template | `ecommerce-frontend-lt` |
| EC2 | Auto Scaling Group | `ecommerce-frontend-asg` (2-6 instances) |
| Beanstalk | Application | `ecommerce-frontend` |
| ECS | Cluster Fargate | `ecommerce-frontend-cluster` |
| EC2 | ALB public | `ecommerce-alb-pub` |
| EC2 | Target Group | `ecommerce-tg-frontend` |
| CloudFront | Distribution | `d1234abcd.cloudfront.net` |
| Route 53 | Record | `ecommerce.votredomaine.com` |
| ACM | Certificat SSL | `*.votredomaine.com` |
| CloudWatch | Dashboard | `ecommerce-monitoring` |

---

## Coûts estimés (eu-west-1, usage modéré)

| Service | Instance | Coût/mois estimé |
|---------|----------|-----------------|
| EKS Cluster | - | ~$73 |
| EC2 Nodes (3 × t3.medium) | - | ~$90 |
| RDS MySQL (db.t3.micro) | - | ~$10-15 |
| NAT Gateway (2 AZ) | - | ~$65 |
| ALB | - | ~$20 |
| ECR (5 repos) | - | ~$5 |
| CloudFront | 10 GB | ~$1 |
| **Total estimé** | | **~$309/mois** |

> 💡 Pour réduire les coûts en développement : utiliser 1 seul NAT GW, des instances `t3.small`, et `db.t3.small`.

---

*Ce guide Console AWS complète le [Guide CLI](./GUIDE-DEPLOIEMENT-MANUEL.md) et le [Terraform](../terraform/). Les trois approches déploient la même architecture.*

---

## Annexe A - AWS Load Balancer Controller (console + kubectl)

Le AWS Load Balancer Controller est indispensable pour que votre Ingress Kubernetes crée automatiquement l'ALB interne EKS. Sans lui, `kubectl get ingress -n ecommerce` reste sans `ADDRESS`.

**Navigation :** Cette étape se fait en CLI depuis votre terminal après avoir configuré kubectl.

```bash
# Depuis votre terminal local (après aws eks update-kubeconfig)
eksctl utils associate-iam-oidc-provider \
  --region eu-west-1 --cluster ecommerce-cluster --approve

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
  --cluster=ecommerce-cluster --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::VOTRE_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=ecommerce-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

**Vérifier dans la console :**  
EC2 → Load Balancers → vous voyez apparaître un ALB avec le schéma **internal** nommé automatiquement par EKS.

---

## Annexe B - HPA : vérification dans la console

**Navigation :** EKS → `ecommerce-cluster` → **Resources** → **Workloads** → **HorizontalPodAutoscalers**

Vous voyez les 4 HPA avec leurs métriques en temps réel :

| Nom | Current | Min | Max |
|-----|---------|-----|-----|
| auth-service | 12% / 70% | 2 | 8 |
| product-service | 8% / 70% | 2 | 10 |
| order-service | 5% / 70% | 2 | 6 |
| review-service | 4% / 70% | 2 | 6 |

**Prérequis :** Le Metrics Server doit être installé sur le cluster.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Sans Metrics Server, les HPAs affichent `<unknown>/70%` dans la colonne TARGETS et ne scalent pas.

---

## Annexe C - Cluster Autoscaler (console EC2 Auto Scaling)

Le Cluster Autoscaler ajuste le nombre de nodes EC2 en fonction des pods en attente de scheduling.

**Installer via terminal :**
```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=ecommerce-cluster \
  --set awsRegion=eu-west-1
```

**Observer dans la console EC2 :**  
EC2 → **Auto Scaling Groups** → `ecommerce-nodes-xxx` → Onglet **Activity**

Vous voyez l'historique des événements de scaling : quand un node a été ajouté (pods pending) ou supprimé (nodes sous-utilisés pendant 10 minutes).

---

## Annexe D - VPC Flow Logs (console)

Les Flow Logs capturent les métadonnées réseau de tout le trafic dans le VPC.

**Navigation :** VPC → **Your VPCs** → `ecommerce-vpc` → Onglet **Flow logs** → **Create flow log**

| Champ | Valeur |
|-------|--------|
| Filter | All |
| Maximum aggregation interval | 1 minute |
| Destination | Send to CloudWatch Logs |
| Destination log group | `/aws/vpc/flowlogs/ecommerce` |
| IAM role | Créer un nouveau rôle → `ecommerce-vpc-flow-log-role` |

Cliquer **Create flow log**

**Analyser les logs :**  
CloudWatch → **Log Insights** → sélectionner `/aws/vpc/flowlogs/ecommerce`

```
# Requête : top 10 des IPs sources les plus actives
fields srcAddr, dstAddr, dstPort, action
| stats count(*) as requests by srcAddr
| sort requests desc
| limit 10
```

---

## Annexe E - CloudTrail (console)

CloudTrail enregistre toutes les actions API AWS : qui a créé/modifié/supprimé quelle ressource, quand, depuis quelle IP.

**Navigation :** Barre de recherche → `CloudTrail` → **Trails** → **Create trail**

| Champ | Valeur |
|-------|--------|
| Trail name | `ecommerce-trail` |
| Storage location | Create new S3 bucket : `ecommerce-cloudtrail-VOTRE_ACCOUNT_ID` |
| Log file SSE-KMS encryption | Désactivé (simplification) |
| CloudWatch Logs | ✅ Enabled → New log group `/aws/cloudtrail/ecommerce` |
| Log events | Management events + Data events (optionnel) |

Cliquer **Create trail**

**Rechercher un événement :**  
CloudTrail → **Event history** → Filtrer par **Event name** = `CreateSecurityGroup` ou `RunInstances`

---

## Annexe F - ECR Lifecycle Policy (console)

**Navigation :** ECR → `ecommerce/auth-service` → **Lifecycle policies** → **Create rule**

| Champ | Valeur |
|-------|--------|
| Rule priority | `1` |
| Rule description | `Garder les 10 dernières images` |
| Image status | `Any` |
| Match criteria | **Image count more than** → `10` |
| Action | **Expire** |

Cliquer **Save** - répéter pour les 4 autres repositories.

---

## Annexe G - Alarmes CloudWatch (console)

**Navigation :** CloudWatch → **Alarms** → **Create alarm**

**Alarme 1 : erreurs 5xx ALB**

1. Cliquer **Select metric** → ApplicationELB → Per AppELB Metrics → `ecommerce-alb-pub` → `HTTPCode_Target_5XX_Count`
2. Stat : Sum | Period : 1 minute
3. Conditions : Greater than `10`
4. Notification : Create new SNS topic → `ecommerce-alerts` → entrer votre email
5. Alarm name : `ecommerce-alb-5xx-errors`

**Alarme 2 : CPU MySQL**

1. Metric → RDS → Per-Database Metrics → `ecommerce-mysql` → `CPUUtilization`
2. Stat : Average | Period : 1 minute
3. Conditions : Greater than `80`
4. Notification : sélectionner `ecommerce-alerts` (créé ci-dessus)
5. Alarm name : `ecommerce-rds-cpu-high`

**Confirmer l'abonnement email :** AWS envoie un email de confirmation SNS - cliquer le lien pour commencer à recevoir les alertes.
