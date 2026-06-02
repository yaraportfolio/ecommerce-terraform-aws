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

EKS et l'AWS Load Balancer Controller ont besoin de tags spécifiques sur les subnets pour savoir où créer les ALB.

**Navigation :** VPC → **Subnets** (menu de gauche)

**Pour chaque subnet public (3 subnets avec "public" dans le nom) :**

Cliquer le subnet → onglet **Tags** → **Manage tags** → **Add new tag** :

| Clé | Valeur | Rôle |
|-----|--------|------|
| `kubernetes.io/role/elb` | `1` | ALB public (internet-facing) |
| `kubernetes.io/cluster/ecommerce-cluster` | `shared` | Découverte par le LBC |

**Pour chaque subnet privé (3 subnets avec "private" dans le nom) :**

| Clé | Valeur | Rôle |
|-----|--------|------|
| `kubernetes.io/role/internal-elb` | `1` | ALB interne (EKS microservices) |
| `kubernetes.io/cluster/ecommerce-cluster` | `shared` | Découverte par le LBC |

> ⚠️ **Le tag `kubernetes.io/cluster/ecommerce-cluster=shared` est obligatoire sur les subnets privés.** Sans lui, l'AWS Load Balancer Controller ne peut pas découvrir les subnets et l'ALB interne EKS ne se crée pas (`unable to resolve at least one subnet`).

> 💡 Ces tags permettent à EKS de savoir dans quels subnets créer les ALB internes (privés, pour les microservices) et externes (publics, pour le frontend).

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

EKS crée et gère le control plane Kubernetes. EKS Auto Mode gère les worker nodes automatiquement.

### 7.1 Créer le cluster EKS

**Navigation :** Barre de recherche → `EKS` → **Elastic Kubernetes Service**

**Cliquer Add cluster → Create**

**Configuration options :**

| Option | Recommandé | Raison |
|--------|-----------|--------|
| **Quick configuration (with EKS Auto Mode)** | ✅ **OUI - Choisir ceci** | Automatisé, defaults production-grade, idéal pour portfolio |
| Custom configuration | Non | Plus complexe, plus de contrôle |

**Cliquer "Quick configuration (with EKS Auto Mode)"**

---

**Step 1 - Configure cluster :**

| Champ | Valeur |
|-------|--------|
| Name | `ecommerce-cluster` |
| Kubernetes version | **1.29** (ou plus récent) |

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
- ✅ Metrics Server (requis pour HPA/autoscaling)
- ✅ **AWS Secrets and Configuration Provider** (requis pour AWS Secrets Manager)

> ⚠️ **Ne pas cocher "Amazon EBS CSI Driver"** — incompatible avec EKS Auto Mode (Create failed).

> ℹ️ **AWS Load Balancer Controller** n'est PAS dans cette liste. Il sera installé séparément via Helm à l'étape 7.5.

**Step 5 - Configure selected add-ons settings :** Laisser les versions par défaut

**Step 6 - Review :** Vérifier → **Create**

Attendre **~12 minutes** que le statut passe à `Active`.

---

### 7.2 Node Pools (Gérés automatiquement avec EKS Auto Mode)

> ℹ️ **Avec EKS Auto Mode, AWS gère TOUS les nodes automatiquement.**
> - Scaling automatique ✅
> - Santé des nodes vérifiée ✅
> - Pas de Node Groups à créer manuellement

**Vérification :** EKS → `ecommerce-cluster` → Onglet **Compute**
- 2 node pools pré-créés : `general-purpose` et `system`
- Nodes avec statut `Ready` créés automatiquement selon la charge

---

### 7.3 Configurer kubectl

**Option A : Via votre machine locale ✅ (recommandé)**

```bash
# Configurer kubectl pour pointer vers EKS
aws eks update-kubeconfig --region eu-west-1 --name ecommerce-cluster

# Vérifier la connexion
kubectl get nodes
# → 2+ nodes avec statut Ready
```

**Option B : Via AWS CloudShell**

EKS → `ecommerce-cluster` → Bouton **"Connect"** → CloudShell

```bash
aws eks update-kubeconfig --region eu-west-1 --name ecommerce-cluster
kubectl get nodes
```

---

### 7.4 Enregistrer l'OIDC Provider (requis pour IRSA)

> ℹ️ **IRSA (IAM Roles for Service Accounts)** permet aux pods Kubernetes d'assumer des rôles IAM AWS sans stocker de credentials. L'OIDC Provider est la clé de confiance entre EKS et IAM.

**Étape 1 — Récupérer l'URL OIDC du cluster :**

EKS → `ecommerce-cluster` → onglet **Overview** → copier la valeur **OpenID Connect provider URL**

```
https://oidc.eks.eu-west-1.amazonaws.com/id/XXXXXXXXXXXX
```

**Étape 2 — Créer le provider dans IAM :**

1. **IAM** → **Identity providers** → **Add provider**
2. **Provider type :** `OpenID Connect`
3. **Provider URL :** coller l'URL copiée ci-dessus
4. Cliquer **Get thumbprint**
5. **Audience :** `sts.amazonaws.com`
6. Cliquer **Add provider**

**Vérification :** IAM → Identity providers → vous devez voir `oidc.eks.eu-west-1.amazonaws.com/id/XXXX` avec le type `OpenID Connect`.

---

### 7.5 Installer AWS Load Balancer Controller

Le **AWS Load Balancer Controller** crée automatiquement un ALB (Application Load Balancer) pour exposer les microservices sur Internet.

#### A. Créer la Policy IAM

1. **IAM** → **Policies** → **Create policy**
2. Cliquer l'onglet **JSON** et coller le contenu de la [policy officielle AWS LBC v2.11](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json)
3. Cliquer **Next**
4. **Policy name :** `AWSLoadBalancerControllerIAMPolicy`
5. Cliquer **Create policy**

---

#### B. Créer le Rôle IAM avec IRSA

1. **IAM** → **Roles** → **Create role**
2. **Trusted entity type :** `Web identity`
3. **Identity provider :** sélectionner `oidc.eks.eu-west-1.amazonaws.com/id/XXXXXXXXXXXX`
4. **Audience :** `sts.amazonaws.com`
5. Cliquer **Next**
6. Rechercher et cocher `AWSLoadBalancerControllerIAMPolicy`
7. Cliquer **Next**
8. **Role name :** `AWSLoadBalancerControllerRole`
9. Cliquer **Create role**

**Étape critique — Restreindre le trust policy au bon ServiceAccount :**

IAM → Roles → `AWSLoadBalancerControllerRole` → onglet **Trust relationships** → **Edit trust policy**

Remplacer le contenu par (adapter `ACCOUNT_ID` et `OIDC_ID`) :

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/OIDC_ID"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.eu-west-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
      }
    }
  }]
}
```

Cliquer **Update policy**

---

#### C. Installer via Helm (terminal local)

Récupérer le **VPC ID** : VPC → `ecommerce-vpc` → copier le **VPC ID** (format `vpc-xxxxxxxxxxxxxxxxx`)

Récupérer l'**ARN du rôle** : IAM → Roles → `AWSLoadBalancerControllerRole` → copier l'ARN

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=ecommerce-cluster \
  --set vpcId=VPC_ID \
  --set region=eu-west-1 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=ARN_DU_ROLE
```

**Vérification :**
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
# → 2 pods avec READY 1/1
```

---

### 7.6 Configurer le Security Group RDS pour EKS

> ℹ️ Les nœuds EKS Auto Mode ont leur propre Security Group créé automatiquement par AWS (différent de `ecommerce-sg-eks`). Il faut l'autoriser à accéder au port 3306 de RDS.

**Étape 1 — Identifier le Security Group des nœuds EKS :**

EC2 → **Instances** → cliquer sur un nœud EKS (nom commence par `i-`) → onglet **Security** → noter le **Security Group ID** (ex: `sg-0xxxxxxxxxxxxxxxxx`)

**Étape 2 — Ajouter la règle au Security Group RDS :**

EC2 → **Security Groups** → chercher le SG attaché à RDS (visible dans RDS → `ecommerce-mysql` → onglet **Connectivity & security** → **VPC security groups**)

Cliquer sur ce SG → onglet **Inbound rules** → **Edit inbound rules** → **Add rule** :

| Champ | Valeur |
|-------|--------|
| Type | `MySQL/Aurora` |
| Protocol | TCP |
| Port range | `3306` |
| Source | `Custom` → sélectionner le SG des nœuds EKS |
| Description | `EKS Auto Mode nodes` |

Cliquer **Save rules**

---

### 7.7 Créer les secrets dans AWS Secrets Manager

**Navigation :** Barre de recherche → `Secrets Manager` → **AWS Secrets Manager**

#### Secret 1 : DB Credentials

1. **Store a new secret**
2. **Secret type :** `Other type of secret`
3. **Key/value pairs :**
   - `DB_USER` → `devops_user`
   - `DB_PASSWORD` → `VOTRE_MOT_DE_PASSE`
4. Cliquer **Next**
5. **Secret name :** `ecommerce/db/credentials`
6. Cliquer **Next** → **Next** → **Store**

#### Secret 2 : JWT Secret

1. **Store a new secret**
2. **Secret type :** `Other type of secret`
3. **Key/value pairs :**
   - `JWT_SECRET` → `VOTRE_JWT_SECRET_LONG_ET_COMPLEXE`
4. Cliquer **Next**
5. **Secret name :** `ecommerce/jwt/secret`
6. Cliquer **Next** → **Next** → **Store**

---

### 7.8 Déployer les microservices via Helm

#### Cloner le repository

```bash
git clone https://github.com/yaraportfolio/ecommerce-k8s-helm.git
cd ecommerce-k8s-helm
```

#### Déployer

```bash
# Récupérer l'endpoint RDS
RDS_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier ecommerce-mysql \
  --region eu-west-1 \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

# Créer le namespace
kubectl create namespace ecommerce

# Déployer via Helm
helm install ecommerce-microservices . \
  --namespace ecommerce \
  --set database.host=$RDS_HOST \
  --set database.password="VOTRE_MOT_DE_PASSE" \
  --set jwt.secret="VOTRE_JWT_SECRET"
```

> ℹ️ Les images GHCR sont **publiques** — aucun secret de registry requis.

#### Vérifier le déploiement

```bash
# Pods Running
kubectl get pods -n ecommerce
# → 4 pods avec READY 1/1

# Récupérer l'URL de l'ALB interne (peut prendre 2-3 minutes)
kubectl get ingress -n ecommerce
# → COLONNE ADDRESS affiche le DNS de l'ALB
# → Format : internal-ecommerce-alb-xxxx.eu-west-1.elb.amazonaws.com
#   (le préfixe "internal-" confirme que l'ALB est privé ✅)
```

> ℹ️ **L'ALB EKS est interne (privé)** — il n'est accessible que depuis l'intérieur du VPC. Il est inaccessible depuis internet, ce qui est le comportement attendu. Les microservices sont joints uniquement par le frontend (EC2/Beanstalk/ECS) via cet ALB interne.

> Pour tester depuis votre machine : utiliser un pod de debug dans le cluster.

```bash
# Test depuis l'intérieur du cluster
ALB=$(kubectl get ingress api-ingress -n ecommerce \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n ecommerce \
  -- curl -s http://$ALB/api/auth/health
# → {"status":"ok","database":"connected"}

kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n ecommerce \
  -- curl -s http://$ALB/api/products | head -c 200
# → Début de la liste des produits JSON
```

**Vérifier dans la console AWS :**
- EC2 → **Load Balancers** → `ecommerce-alb` → statut **Active** → Scheme : **internal** ✅
- EKS → `ecommerce-cluster` → **Resources** → **Pods** → Namespace `ecommerce` → 4 pods Running

**Noter l'URL de l'ALB interne** — elle sera utilisée dans la config NGINX du frontend (sections 8, 9, 10) :
```
internal-ecommerce-alb-xxxx.eu-west-1.elb.amazonaws.com
```

---

## 8. Frontend Option A - EC2 + Auto Scaling

Cette option déploie le frontend React (build statique) servi par **NGINX directement sur EC2**, sans Docker. L'Auto Scaling Group assure la haute disponibilité.

> 💡 **Indicateur visuel portfolio** : La variable `VITE_DEPLOY_PLATFORM=ec2` affiche un badge **"☁️ EC2 + ASG"** dans la navbar du site.

---

### 8.1 Créer un rôle IAM pour les instances EC2

**Navigation :** IAM → **Roles** → **Create role**

| Champ | Valeur |
|-------|--------|
| Trusted entity type | **AWS service** |
| Use case | **EC2** |

Cliquer **Next** → Rechercher et ajouter ces policies :
- `AmazonSSMManagedInstanceCore` ← accès Session Manager (sans clé SSH)

**Role name :** `ecommerce-frontend-ec2-role` → **Create role**

---

### 8.2 Créer le Launch Template

**Navigation :** EC2 → **Launch Templates** → **Create launch template**

| Champ | Valeur |
|-------|--------|
| Launch template name | `ecommerce-frontend-lt` |
| Template version description | `v1 - NGINX + React direct` |

**Application and OS Images :**
- **Quick Start** → **Amazon Linux 2023 AMI** → `x86_64`

**Instance type :** `t3.micro` (Free Tier) ou `t3.small`

**Key pair :** Aucune (on utilisera Session Manager)

**Network settings :**
- Security groups : `ecommerce-sg-frontend`

**Advanced details :**
- IAM instance profile : `ecommerce-frontend-ec2-role`
- User data : coller le script suivant

```bash
#!/bin/bash
# Variables — ALB interne EKS (récupéré à l'étape 7.8)
# Format : internal-ecommerce-alb-xxxx.eu-west-1.elb.amazonaws.com
ALB_URL="http://internal-ecommerce-alb-xxxx.eu-west-1.elb.amazonaws.com"

# Mise à jour système + outils
dnf update -y
dnf install -y nginx git nodejs npm

# Cloner le frontend
cd /opt
git clone https://github.com/yaraportfolio/ecommerce-frontend.git
cd ecommerce-frontend

# Build React avec la plateforme EC2 + URL backend
cat > .env.production << EOF
VITE_DEPLOY_PLATFORM=ec2
EOF

npm ci
npm run build

# Copier le build vers NGINX
cp -r dist/* /usr/share/nginx/html/

# Configurer NGINX (proxy backend + SPA fallback)
cat > /etc/nginx/conf.d/ecommerce.conf << 'NGINXEOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    # SPA - toutes les routes vers index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Proxy vers les microservices EKS via ALB
    location /api/ {
        proxy_pass ALB_PLACEHOLDER/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINXEOF

# Remplacer le placeholder par l'URL ALB réelle
sed -i "s|ALB_PLACEHOLDER|${ALB_URL}|g" /etc/nginx/conf.d/ecommerce.conf

# Démarrer NGINX
systemctl enable nginx
systemctl start nginx
```

> ⚠️ Remplacer `internal-ecommerce-alb-xxxx.eu-west-1.elb.amazonaws.com` par l'URL réelle récupérée à l'étape 7.8 (`kubectl get ingress -n ecommerce`). L'ALB EKS est **interne** — accessible uniquement depuis les instances EC2 dans le même VPC.

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
| Min desired capacity | `1` |
| Max desired capacity | `4` |

**Automatic scaling :**
- ✅ **Target tracking scaling policy**
- Metric type : **Average CPU utilization**
- Target value : `70`

**Step 6 - Add tags :**

| Key | Value |
|-----|-------|
| Name | `ecommerce-frontend-ec2` |
| Env | `prod` |
| Platform | `ec2` |

Cliquer **Create Auto Scaling group**

Attendre ~3-5 minutes que les instances démarrent, que le User Data s'exécute (clone + build + NGINX), et que le health check passe.

---

### 8.4 Se connecter à l'instance EC2 (Session Manager)

> ℹ️ Pas besoin de clé SSH. Session Manager permet une connexion sécurisée directement depuis la console AWS.

1. EC2 → **Instances** → sélectionner une instance `ecommerce-frontend-ec2`
2. Cliquer **Connect** → onglet **Session Manager** → **Connect**
3. Un terminal s'ouvre dans le navigateur

```bash
# Vérifier que NGINX tourne
sudo systemctl status nginx

# Vérifier que le build React est présent
ls /usr/share/nginx/html/

# Voir les logs NGINX
sudo tail -f /var/log/nginx/access.log

# Tester le proxy backend (ALB interne EKS)
curl http://localhost/api/auth/health
# → {"status":"ok","database":"connected"}
```

**Pour mettre à jour le frontend manuellement :**
```bash
cd /opt/ecommerce-frontend
sudo git pull
sudo npm ci
sudo npm run build
sudo cp -r dist/* /usr/share/nginx/html/
sudo systemctl reload nginx
```

---

## 9. Frontend Option B - Elastic Beanstalk

Beanstalk gère tout automatiquement : EC2, ALB, autoscaling. Idéal pour comprendre le modèle PaaS.

> 💡 **Indicateur visuel portfolio** : La variable `VITE_DEPLOY_PLATFORM=beanstalk` affiche un badge **"☁️ Elastic Beanstalk"** dans la navbar du site.

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

> 💡 **Indicateur visuel portfolio** : La variable `VITE_DEPLOY_PLATFORM=ecs` affiche un badge **"☁️ ECS Fargate"** dans la navbar du site.

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
