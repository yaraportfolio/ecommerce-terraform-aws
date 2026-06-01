# Architecture - E-Commerce Microservices sur AWS

**Auteur :** Yara Mahi Mohamed | Portfolio DevOps & SRE  
**Stack :** React 18 + NGINX · Node.js 20 · MariaDB → RDS MySQL · EKS + Helm  
**Région principale :** `eu-west-1` (Irlande)

---

## Sommaire

1. [Vue d'ensemble](#1-vue-densemble)
2. [Schéma global](#2-schéma-global)
3. [Couche DNS & CDN](#3-couche-dns--cdn)
4. [Réseau - VPC & subnets](#4-réseau--vpc--subnets)
5. [Sécurité - Security Groups](#5-sécurité--security-groups)
6. [Frontend - trois modes de déploiement](#6-frontend--trois-modes-de-déploiement)
7. [Load Balancer public](#7-load-balancer-public)
8. [EKS - cluster Kubernetes](#8-eks--cluster-kubernetes)
9. [Microservices](#9-microservices)
10. [Base de données - RDS MySQL](#10-base-de-données--rds-mysql)
11. [Registry - ECR](#11-registry--ecr)
12. [Secrets & IAM](#12-secrets--iam)
13. [Observabilité](#13-observabilité)
14. [Flux de données complet](#14-flux-de-données-complet)
15. [Correspondances OCI → AWS](#15-correspondances-oci--aws)
16. [Décisions d'architecture](#16-décisions-darchitecture)
17. [Estimations de coûts](#17-estimations-de-coûts)

---

## 1. Vue d'ensemble

L'architecture déploie une application e-commerce composée de cinq services distincts sur AWS, en suivant les principes microservices et la séparation stricte des couches réseau.

```
Navigateur
    │
    ▼
Route 53 → CloudFront (CDN + WAF + SSL)
    │
    ▼
ALB public (HTTPS :443)
    │
    ├── Option A : EC2 + Auto Scaling Group
    ├── Option B : Elastic Beanstalk
    └── Option C : ECS Fargate
                │ (les 3 servent le même frontend React + NGINX)
                ▼
         ALB interne EKS (Ingress Controller)
                │
    ┌───────────┼─────────────┬────────────┐
    ▼           ▼             ▼            ▼
auth:3001  product:3002  order:3003  review:3004
    │           │             │            │
    └───────────┴─────────────┴────────────┘
                       │ MySQL :3306
                 RDS MySQL
                  (ecommerce_db)
```

### Ce qui vient de l'infra locale (OCI/on-premise)

| Infra locale | Équivalent AWS | Note |
|-------------|----------------|------|
| IP fixe `192.168.56.115` (MariaDB) | RDS MySQL endpoint DNS | Bascule automatique en cas de panne |
| IP fixe `192.168.56.111` (K8s NodePort 30080) | ALB interne EKS | Créé automatiquement par AWS LB Controller |
| IP fixe `192.168.56.114` (Frontend VM) | ALB public + ASG/Beanstalk/ECS | Remplacé par une couche managée |
| GHCR (`ghcr.io/yaraportfolio/*`) | ECR (`ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/*`) | Images migrées au premier déploiement |
| MariaDB 10.11 | MySQL 8.0 | 100% compatible - drivers `mysql2` et schéma SQL inchangés |

**Ce qui ne change pas :** le code des microservices, le Helm chart, l'image Docker frontend, la variable `BACKEND_URL` injectée par `envsubst`, et le schéma `ecommerce_db.sql`.

---

## 2. Schéma global

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  INTERNET                                                                    │
│                        Navigateur utilisateur                                │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ HTTPS
                         ┌─────────────┼─────────────┐
                         ▼             ▼             ▼
                    Route 53      CloudFront         ACM
                    (DNS)         (CDN mondial)    (SSL/TLS)
                         └─────────────┬─────────────┘
                                       │ HTTPS :443
┌──────────────────────────────────────────────────────────────────────────────┐
│  VPC - 10.0.0.0/16 (eu-west-1)                                               │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │ Subnets publics - 10.0.1-3.0/24 (eu-west-1a/b/c)                      │   │
│  │                                                                       │   │
│  │           ALB public - ecommerce-alb-pub                              │   │
│  │           SG-ALB : :80 :443 ← 0.0.0.0/0                               │   │
│  │                     │                                                 │   │
│  │      ┌──────────────┼──────────────┐                                  │   │
│  │      ▼              ▼              ▼                                  │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  SG-Frontend : :80 ← SG-ALB │   │
│  │  │   EC2    │  │Beanstalk │  │   ECS    │                             │   │
│  │  │   ASG    │  │  (PaaS)  │  │ Fargate  │  NGINX + React build        │   │
│  │  │  Option  │  │ Option B │  │ Option C │  BACKEND_URL → ALB interne  │   │
│  │  │    A     │  │          │  │          │                             │   │
│  │  └──────────┘  └──────────┘  └──────────┘                             │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                      │                                       │
│                                      ▼ HTTP                                  │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │  Subnets privés - 10.0.10-12.0/24 (eu-west-1a/b)                      │   │
│  │                                                                       │   │
│  │        ALB interne - Ingress EKS (AWS LB Controller)                  │   │
│  │                         │                                             │   │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │   │
│  │  │  EKS - ecommerce-cluster (Kubernetes 1.29)                       │ │   │
│  │  │  Node Group : t3.medium × 2-6 · HPA activé                       │ │   │
│  │  │                                                                  │ │   │
│  │  │  namespace: ecommerce                                            │ │   │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ │ │   │
│  │  │  │ auth-svc    │ │ product-svc │ │ order-svc   │ │ review-svc  │ │ │   │
│  │  │  │ :3001       │ │ :3002       │ │ :3003       │ │ :3004       │ │ │   │
│  │  │  │ 2-8 pods    │ │ 2-10 pods   │ │ 2-6 pods    │ │ 2-6 pods    │ │ │   │
│  │  │  │ HPA CPU70%  │ │ HPA CPU70%  │ │ HPA CPU70%  │ │ HPA CPU70%  │ │ │   │
│  │  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘ │ │   │
│  │  └──────────────────────────────────────────────────────────────────┘ │   │
│  │                SG-EKS : :3001-3004 ← SG-Frontend · self               │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                     │ MySQL :3306                            │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │  Subnets DB - 10.0.20-21.0/24 (eu-west-1a/b)                          │   │
│  │                                                                       │   │
│  │    ┌────────────────────────────────────────┐                         │   │
│  │    │  RDS MySQL - ecommerce-mysql           │                         │   │
│  │    │  Endpoint : mysql-xxx.rds.aws          │                         │   │
│  │    │  db.t3.micro · Multi-AZ · chiffré      │                         │   │
│  │    │  ecommerce_db · backups 7 jours        │                         │   │
│  │    └────────────────────────────────────────┘                         │   │
│  │                SG-RDS : :3306 ← SG-EKS uniquement                     │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  Services transversaux (dans le VPC ou global)                               │
│  ECR · Secrets Manager · CloudWatch · CloudTrail · IAM                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Couche DNS & CDN

### Route 53

Route 53 est le service DNS d'AWS. Il remplace les entrées `/etc/hosts` et les DNS locaux de l'infra on-premise.

**Rôle dans cette architecture :**
- Résolution du domaine principal (`ecommerce.votredomaine.com`) vers la distribution CloudFront
- Health checks automatiques sur l'ALB - en cas de panne d'une région, Route 53 peut rediriger vers un failover
- Alias record (A record vers CloudFront) - pas de TTL court à gérer, la résolution est immédiate côté AWS

**Pourquoi un alias record et pas un CNAME :** Les CNAMEs ne peuvent pas pointer vers la racine d'un domaine (`votredomaine.com` sans sous-domaine). Les alias records AWS permettent de le faire et sont gratuits (pas de frais de requête DNS pour les alias vers services AWS).

### CloudFront

CloudFront est le CDN (Content Delivery Network) d'AWS. Il positionne des copies du contenu statique dans des edge locations à travers le monde (plus de 400 points de présence).

**Rôle dans cette architecture :**
- Mise en cache des assets statiques du frontend React (JS, CSS, images) - réduit la charge sur l'ALB
- Terminaison SSL/TLS au niveau de l'edge - le certificat ACM est attaché ici
- WAF (Web Application Firewall) - peut filtrer les attaques SQL injection, XSS, rate limiting
- Deux behaviors configurés : `/api/*` sans cache (forward vers ALB), `/*` avec cache agressif

**Comportement de l'envsubst NGINX :** Le frontend React est une SPA statique - le fichier `dist/` est servi par NGINX. La variable `BACKEND_URL` est injectée au démarrage du conteneur par `envsubst` dans la config NGINX, ce qui signifie que les requêtes `/api/...` sont proxifiées par NGINX vers l'ALB interne EKS. CloudFront ne voit que du HTTP/HTTPS vers l'ALB public - il ne touche pas au proxy interne.

### ACM - AWS Certificate Manager

Gère le cycle de vie des certificats SSL/TLS (création, renouvellement automatique, révocation). Les certificats sont attachés aux listeners HTTPS de l'ALB et de CloudFront. Renouvellement automatique avant expiration - zéro gestion manuelle.

---

## 4. Réseau - VPC & subnets

### VPC principal

| Paramètre | Valeur |
|-----------|--------|
| CIDR | `10.0.0.0/16` |
| DNS support | Activé |
| DNS hostnames | Activé (requis pour RDS et EKS) |
| Région | `eu-west-1` |
| Availability Zones | `eu-west-1a`, `eu-west-1b`, `eu-west-1c` |

### Découpage des subnets

L'architecture sépare les ressources en trois niveaux d'isolation réseau :

**Subnets publics** - exposés à internet via l'Internet Gateway. Les ressources ici ont une IP publique et peuvent recevoir du trafic entrant.

| Nom | CIDR | AZ | Ressources |
|-----|------|----|-----------|
| ecommerce-pub-a | 10.0.1.0/24 | eu-west-1a | ALB public, NAT Gateway, EC2 frontend, ECS tasks |
| ecommerce-pub-b | 10.0.2.0/24 | eu-west-1b | ALB public, NAT Gateway, EC2 frontend, ECS tasks |
| ecommerce-pub-c | 10.0.3.0/24 | eu-west-1c | ALB public, EC2 frontend |

**Subnets privés** - pas d'accès internet entrant. Les ressources sortent vers internet via la NAT Gateway (pour puller des images ECR, appeler des APIs AWS, etc.).

| Nom | CIDR | AZ | Ressources |
|-----|------|----|-----------|
| ecommerce-priv-a | 10.0.10.0/24 | eu-west-1a | Nodes EKS, pods microservices |
| ecommerce-priv-b | 10.0.11.0/24 | eu-west-1b | Nodes EKS, pods microservices |

Tags Kubernetes obligatoires sur ces subnets :
- `kubernetes.io/role/internal-elb = 1` → EKS crée les ALB internes ici

**Subnets base de données** - isolés, sans route vers internet, sans NAT. Seule la communication via le Security Group depuis les nodes EKS est autorisée.

| Nom | CIDR | AZ | Ressources |
|-----|------|----|-----------|
| ecommerce-db-a | 10.0.20.0/24 | eu-west-1a | RDS MySQL primary |
| ecommerce-db-b | 10.0.21.0/24 | eu-west-1b | RDS MySQL standby |

### Tables de routage

Chaque niveau a sa propre table de routage :

**Table publique** - une seule pour les trois subnets publics :
```
Destination     Target
0.0.0.0/0       igw-xxx (Internet Gateway)
10.0.0.0/16     local
```

**Tables privées** - une par AZ, chacune avec sa propre NAT Gateway (résilience : si eu-west-1a tombe, le trafic de eu-west-1b continue via son propre NAT) :
```
Destination     Target
0.0.0.0/0       nat-xxx-a (NAT Gateway dans pub-a)
10.0.0.0/16     local
```

**Tables DB** - associées aux tables privées, pas de route internet. Les subnets DB utilisent les mêmes tables de routage que les subnets privés de la même AZ.

### NAT Gateway

Deux NAT Gateways (une par AZ utilisée) permettent aux nodes EKS de sortir vers internet (pull d'images ECR, appels AWS SDK, mises à jour système) sans être exposés. Chaque NAT Gateway a une Elastic IP fixe.

**Coût à noter :** les NAT Gateways coûtent ~$0.045/h + $0.045/GB transféré. C'est souvent le poste de coût le plus surprenant pour les débutants AWS. En dev, une seule NAT Gateway suffit (supprimer la redondance AZ).

---

## 5. Sécurité - Security Groups

Les Security Groups sont des pare-feux stateful attachés à chaque ressource (ENI - Elastic Network Interface). La règle fondamentale de cette architecture : **chaque SG référence le SG de la couche précédente comme source, pas un CIDR IP**.

### Pourquoi référencer des SGs plutôt que des CIDRs

Avec un CIDR (`10.0.1.0/24`), si une instance change d'IP ou si un subnet est redécoupé, les règles deviennent incorrectes. Avec un SG comme source, la règle s'applique à toute ressource portant ce SG, quelle que soit son IP. C'est plus robuste et plus lisible.

### Chaîne des Security Groups

```
Internet (0.0.0.0/0)
    │ :80 :443
    ▼
SG-ALB (ecommerce-sg-alb)
    │ :80 ← source: SG-ALB
    ▼
SG-Frontend (ecommerce-sg-frontend)
    │ :3001 :3002 :3003 :3004 ← source: SG-Frontend
    │ self (communication intra-cluster)
    ▼
SG-EKS (ecommerce-sg-eks)
    │ :3306 ← source: SG-EKS
    ▼
SG-RDS (ecommerce-sg-rds)
```

### Détail de chaque Security Group

**SG-ALB** - point d'entrée internet

| Direction | Protocol | Port | Source/Dest |
|-----------|----------|------|------------|
| Inbound | TCP | 80 | 0.0.0.0/0 |
| Inbound | TCP | 443 | 0.0.0.0/0 |
| Outbound | All | All | 0.0.0.0/0 |

**SG-Frontend** - instances frontend (EC2, Beanstalk, ECS)

| Direction | Protocol | Port | Source/Dest |
|-----------|----------|------|------------|
| Inbound | TCP | 80 | SG-ALB |
| Outbound | All | All | 0.0.0.0/0 |

Note : aucun port SSH (22) exposé. L'accès aux instances se fait via AWS Systems Manager Session Manager.

**SG-EKS** - nodes Kubernetes et pods

| Direction | Protocol | Port | Source/Dest |
|-----------|----------|------|------------|
| Inbound | TCP | 3001 | SG-Frontend |
| Inbound | TCP | 3002 | SG-Frontend |
| Inbound | TCP | 3003 | SG-Frontend |
| Inbound | TCP | 3004 | SG-Frontend |
| Inbound | All | All | SG-EKS (self) |
| Outbound | All | All | 0.0.0.0/0 |

La règle self est critique pour EKS : elle permet la communication pod-to-pod, node-to-node, et les health checks Kubernetes.

**SG-RDS** - base de données Aurora

| Direction | Protocol | Port | Source/Dest |
|-----------|----------|------|------------|
| Inbound | TCP | 3306 | SG-EKS |
| Outbound | All | All | 0.0.0.0/0 |

La base de données n'est joignable que depuis les nodes EKS. Ni le frontend, ni internet, ni un bastion n'y accèdent directement en production.

---

## 6. Frontend - trois modes de déploiement

Le frontend est identique dans les trois cas : une image Docker `nginx:stable-alpine` avec le build React `dist/` et la configuration NGINX qui proxifie `/api/*` vers l'ALB interne EKS. La variable `BACKEND_URL` est injectée dynamiquement par `envsubst` au démarrage du conteneur - aucun rebuild nécessaire pour changer de backend.

### Option A - EC2 + Auto Scaling Group

**Principe :** Des VMs EC2 classiques. Au démarrage de chaque VM, le User Data script installe Docker, se connecte à ECR, et lance le conteneur frontend.

**Composants :**
- **Launch Template** : définit l'AMI (Amazon Linux 2023), le type d'instance (`t3.medium`), le Security Group, le rôle IAM, et le script User Data
- **Auto Scaling Group (ASG)** : maintient entre 2 et 6 instances selon la charge CPU. Déploiement sur les 3 subnets publics (multi-AZ). Intégration avec l'ALB via le Target Group
- **Target Group** : health check sur `GET /` toutes les 30 secondes. Les instances unhealthy sont déregistrées de l'ALB et remplacées par l'ASG

**Avantages :** contrôle total sur la VM (debugging, accès SSH via SSM), familiarité pour les équipes Ops, coût prévisible (instances On-Demand)

**Inconvénients :** temps de démarrage (~2-3 minutes au scale-out), gestion du système d'exploitation (patches), pas de "scale to zero"

**Cas d'usage :** production avec charge prévisible, équipes qui veulent comprendre la couche infra avant d'abstraire

### Option B - Elastic Beanstalk

**Principe :** PaaS géré par AWS. On fournit un fichier `Dockerrun.aws.json` décrivant l'image et les variables d'environnement. Beanstalk provisionne automatiquement EC2, ALB, ASG, et les health checks.

**Composants :**
- **Application** : conteneur logique regroupant les versions et environnements
- **Environment** : l'infrastructure active (EC2 + ALB + ASG + SGs créés par Beanstalk)
- **Dockerrun.aws.json** : déclare l'image ECR à utiliser, le port, et les variables d'environnement

**Configuration clé pour cette architecture :**
```json
{
  "AWSEBDockerrunVersion": "1",
  "Image": {
    "Name": "ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com/ecommerce/frontend:latest",
    "Update": "true"
  },
  "Ports": [{ "ContainerPort": "80" }],
  "Environment": [
    { "Name": "BACKEND_URL", "Value": "http://ALB_INTERNE_EKS" },
    { "Name": "BACKEND_HOST", "Value": "api.ecommerce.local" }
  ]
}
```

**Stratégie de déploiement :** Rolling (50% des instances à la fois) - évite les downtime lors des mises à jour.

**Avantages :** déploiement en une commande, pas de gestion d'ASG ou d'ALB, health checks automatiques, logs CloudWatch intégrés

**Inconvénients :** moins de contrôle sur l'infra sous-jacente, configurations avancées via `.ebextensions` (verbeux), difficile à déboguer quand le problème vient de Beanstalk lui-même

**Cas d'usage :** équipes produit sans DevOps dédié, prototypage rapide, migration depuis une app monolithique

### Option C - ECS Fargate

**Principe :** Conteneurs managés sans serveur à gérer. AWS alloue du CPU et de la mémoire à la demande pour chaque task, sans node EC2 visible.

**Composants :**
- **Cluster ECS** : regroupement logique des services. Configuré avec FARGATE (On-Demand) et FARGATE_SPOT (interruptible, 70% moins cher) en mode mixed (1:4)
- **Task Definition** : blueprint du conteneur - image, CPU/mémoire, ports, variables d'env, configuration des logs. Chaque révision est immutable
- **Service ECS** : maintient N tasks en cours d'exécution, intègre avec l'ALB via le Target Group, gère les rolling deployments

**Avantages :** scale to zero possible, facturation à la seconde, zéro gestion des nodes, FARGATE_SPOT pour réduire les coûts de 70%

**Inconvénients :** démarrage à froid (~30s vs ~5s pour EC2), pas d'accès SSH direct (ECS Exec pour le debugging), plus cher qu'EC2 pour des charges soutenues et prévisibles

**Cas d'usage :** workloads variables ou intermittents, déploiements blue/green, équipes qui veulent focus sur l'application pas l'infra

### Résumé comparatif

| Critère | EC2 ASG | Beanstalk | ECS Fargate |
|---------|---------|-----------|-------------|
| Temps de déploiement | ~5min | ~5min | ~2min |
| Scale-out | ~3min | ~3min | ~30s |
| Scale to zero | Non | Non | Oui |
| Contrôle infra | Total | Partiel | Minimal |
| Debugging | SSH/SSM | SSM/EB logs | ECS Exec |
| Coût charge stable | Le moins cher | Identique EC2 | Le plus cher |
| Coût charge variable | Moyen | Moyen | Meilleur (Spot) |
| Complexité opérationnelle | Élevée | Faible | Moyenne |

---

## 7. Load Balancer public

### ALB - Application Load Balancer

L'ALB opère au niveau L7 (HTTP/HTTPS). Il termine le SSL, inspecte les headers HTTP, et route vers le Target Group approprié.

**Caractéristiques :**
- Scheme : **internet-facing** (IP publique)
- Subnets : les **3 subnets publics** (multi-AZ obligatoire pour un ALB)
- Security Group : SG-ALB (:80 :443 depuis 0.0.0.0/0)

**Listeners :**

*Listener HTTP :80* → Redirect vers HTTPS :443 (code 301). Aucun trafic ne transite en clair.

*Listener HTTPS :443* → Forward vers le Target Group `ecommerce-tg-frontend`. SSL Policy : `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 + TLS 1.2, sans ciphers faibles).

**Target Group `ecommerce-tg-frontend` :**
- Target type : `instance` (pour EC2/Beanstalk) ou `ip` (pour ECS Fargate)
- Protocol : HTTP :80
- Health check : `GET /` toutes les 30s, seuil healthy : 2, unhealthy : 3
- Deregistration delay : 30s (les connexions existantes ont 30s pour se terminer lors d'un scale-in)

### Sticky sessions

Non activées par défaut. Le frontend React est une SPA stateless - chaque requête peut aller sur n'importe quelle instance. Les JWT sont validés par les microservices, pas stockés côté serveur.

---

## 8. EKS - cluster Kubernetes

### Cluster

| Paramètre | Valeur |
|-----------|--------|
| Nom | `ecommerce-cluster` |
| Version Kubernetes | 1.29 |
| Endpoint access | Public + Private |
| Subnets | Privés eu-west-1a et eu-west-1b |
| Add-ons | CoreDNS · kube-proxy · Amazon VPC CNI · EBS CSI Driver |

**Public + Private endpoint :** le control plane EKS est accessible depuis internet (pour les commandes `kubectl` depuis votre machine) ET depuis le VPC (pour les nodes qui s'enregistrent au control plane). En production stricte, on passerait en Private only + VPN pour accéder au control plane.

### Node Group

| Paramètre | Valeur |
|-----------|--------|
| Nom | `ecommerce-nodes` |
| Instance type | `t3.medium` (2 vCPU, 4 GB RAM) |
| AMI | Amazon Linux 2 (AL2_x86_64) |
| Min / Max / Desired | 2 / 6 / 3 |
| Subnets | Privés uniquement |
| Cluster Autoscaler | Activé - scale automatique selon les pods pending |

**Pourquoi t3.medium :** chaque microservice demande 100m CPU et 128Mi RAM au minimum. Sur un t3.medium, on peut faire tourner ~8-10 pods confortablement. Avec 3 nodes, la capacité totale est d'environ 24-30 pods, ce qui permet de faire tourner les 8 pods de base (2 réplicas × 4 services) avec de la marge pour le HPA.

### Amazon VPC CNI

Le plugin réseau Amazon VPC CNI assigne des vraies IPs du VPC à chaque pod (pas de réseau overlay). Un pod sur `10.0.10.15` est directement joignable depuis n'importe quel autre point du VPC à cette IP. C'est différent de Flannel ou Calico qui créent un réseau virtuel superposé.

**Conséquence :** chaque node EC2 peut héberger autant de pods qu'il a d'IP secondaires disponibles. Sur un `t3.medium`, c'est 17 IP secondaires = 17 pods max par node.

### AWS Load Balancer Controller

Le AWS Load Balancer Controller est un Ingress Controller qui traduit les ressources Kubernetes `Ingress` en ALB AWS réels.

Quand Helm déploie l'Ingress de l'architecture :
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
spec:
  rules:
  - http:
      paths:
      - path: /api/auth
        backend:
          service:
            name: auth-service
            port:
              number: 3001
      - path: /api/products
        ...
```

Le controller crée automatiquement un ALB interne dans les subnets privés, configure les Target Groups pour chaque service, et les health checks correspondent aux probes Kubernetes.

### HPA - Horizontal Pod Autoscaler

Chaque microservice a un HPA configuré dans le Helm chart :

| Service | Min replicas | Max replicas | Trigger CPU |
|---------|-------------|-------------|-------------|
| auth-service | 2 | 8 | 70% |
| product-service | 2 | 10 | 70% |
| order-service | 2 | 6 | 70% |
| review-service | 2 | 6 | 70% |

Le HPA interagit avec le Cluster Autoscaler : si les pods pending ne peuvent pas être schedulés (nodes pleins), le Cluster Autoscaler ajoute un node EC2 automatiquement (~3 minutes).

### Helm chart

Le déploiement des microservices utilise le chart `ecommerce-k8s-helm` existant, avec un fichier `values` adapté pour AWS :

```yaml
image:
  registryType: ecr
  ecr:
    registry: ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com
    owner: ecommerce

database:
  host: "cluster-xxx.eu-west-1.rds.amazonaws.com"
  # password : injecté via set_sensitive Terraform / kubectl secret

jwt:
  # secret : injecté via set_sensitive Terraform / kubectl secret
```

Les secrets DB et JWT sont passés en `--set-sensitive` dans Terraform ou créés manuellement avec `kubectl create secret` - ils ne transitent jamais dans les fichiers values versionnés.

---

## 9. Microservices

Les quatre microservices sont des applications Node.js 20 / Express identiques en structure. Ils partagent la même base de données `ecommerce_db` sur RDS MySQL et le même `JWT_SECRET`.

### auth-service - Port 3001

**Rôle :** authentification JWT. Point central de toute l'architecture - les autres services valident les tokens émis ici.

**Endpoints :**
| Méthode | Route | Auth | Description |
|---------|-------|------|-------------|
| POST | /api/auth/register | - | Inscription utilisateur |
| POST | /api/auth/login | - | Connexion → JWT 24h |
| GET | /api/auth/me | JWT | Profil utilisateur courant |
| GET | /api/auth/health | - | Liveness probe Kubernetes |
| GET | /api/auth/ready | - | Readiness probe Kubernetes |
| GET | /api/auth/metrics | - | Métriques Prometheus |

**Tables utilisées :** `users` (email, password_hash bcrypt, role, created_at)

**Variables d'environnement :**
```
PORT=3001
DB_HOST=cluster-xxx.eu-west-1.rds.amazonaws.com
DB_PORT=3306
DB_NAME=ecommerce_db
DB_USER=devops_user
DB_PASSWORD=<depuis Secrets Manager>
JWT_SECRET=<depuis Secrets Manager>
JWT_EXPIRATION=24h
```

### product-service - Port 3002

**Rôle :** catalogue produits. Seul service public (lecture sans auth). Les opérations d'écriture (CRUD) requièrent un JWT admin.

**Endpoints :**
| Méthode | Route | Auth | Description |
|---------|-------|------|-------------|
| GET | /api/products | - | Liste complète |
| GET | /api/products/:id | - | Détail produit |
| GET | /api/products/search?q= | - | Recherche fulltext (index FULLTEXT MySQL) |
| GET | /api/products/category/:cat | - | Filtrage par catégorie |
| POST | /api/products | Admin | Créer un produit |
| PUT | /api/products/:id | Admin | Modifier |
| DELETE | /api/products/:id | Admin | Supprimer |
| GET | /api/products/health | - | Liveness probe |
| GET | /api/products/metrics | - | Métriques Prometheus |

**Tables utilisées :** `products` (name, description, price, stock, category, image_url)

**Note sur le fulltext search :** La table `products` a un index `FULLTEXT` sur `(name, description)` - la route `/search?q=laptop` utilise `MATCH(name, description) AGAINST(? IN BOOLEAN MODE)`. Compatible Aurora MySQL 8.0.

### order-service - Port 3003

**Rôle :** gestion complète du cycle de vie des commandes. Tous les endpoints requièrent un JWT valide. Les utilisateurs ne voient que leurs propres commandes, les admins voient tout.

**Endpoints :**
| Méthode | Route | Auth | Description |
|---------|-------|------|-------------|
| GET | /api/orders | JWT | Mes commandes |
| POST | /api/orders | JWT | Créer une commande |
| GET | /api/orders/:id | JWT/Admin | Détail commande |
| PUT | /api/orders/:id/status | Admin | Changer le statut |
| GET | /api/orders/all | Admin | Toutes les commandes |
| GET | /api/orders/health | - | Liveness probe |
| GET | /api/orders/metrics | - | Métriques Prometheus |

**Cycle de vie d'une commande :** `pending` → `processing` → `shipped` → `delivered` / `cancelled`

**Tables utilisées :** `orders` (user_id, total_amount, status, shipping_address), `order_items` (order_id, product_id, quantity, unit_price)

Note sur `unit_price` : le prix est stocké au moment de la commande, pas une référence vers le prix actuel du produit. Cela garantit que le montant affiché dans l'historique ne change pas si le prix du produit évolue.

### review-service - Port 3004

**Rôle :** avis et notations produits. Lecture publique, écriture authentifiée. Contrainte métier forte : 1 avis maximum par utilisateur par produit.

**Endpoints :**
| Méthode | Route | Auth | Description |
|---------|-------|------|-------------|
| GET | /api/reviews/product/:id | - | Avis d'un produit |
| POST | /api/reviews | JWT | Créer un avis (1 max) |
| PUT | /api/reviews/:id | JWT/Admin | Modifier un avis |
| DELETE | /api/reviews/:id | JWT/Admin | Supprimer un avis |
| GET | /api/reviews | Admin | Tous les avis (modération) |
| GET | /api/reviews/health | - | Liveness probe |
| GET | /api/reviews/metrics | - | Métriques Prometheus |

**Contrainte d'unicité :** Un `UNIQUE INDEX` sur `(user_id, product_id)` dans la table `reviews` garantit qu'un même utilisateur ne peut pas soumettre deux avis pour le même produit. Toute tentative retourne une erreur `409 Conflict`.

**Tables utilisées :** `reviews` (product_id, user_id, rating 1-5, comment, created_at)

### Métriques Prometheus

Chaque service expose `/metrics` via le module `prom-client`. Les métriques exposées sont :

```
# Node.js runtime
nodejs_heap_size_total_bytes
nodejs_heap_used_bytes
process_cpu_seconds_total

# HTTP personnalisées
http_requests_total{method, route, status_code}
http_request_duration_seconds{quantile}
http_request_errors_total
```

Sur EKS, si le Prometheus Operator est déployé, les `ServiceMonitor` du Helm chart activent le scraping automatique. Sinon, CloudWatch Container Insights collecte les métriques système.

---

## 10. Base de données - RDS MySQL

### Configuration MySQL 8.0

MySQL 8.0 est compatible avec MariaDB 10.11 déployée localement. Votre schéma `ecommerce_db.sql`, vos drivers `mysql2` Node.js, et vos requêtes SQL fonctionnent sans modification. Le seul changement est l'endpoint de connexion.

**Caractéristiques MySQL 8.0 sur RDS :**
- **Compatibilité :** drivers `mysql2` et schéma SQL inchangés
- **Multi-AZ :** réplication synchrone vers un standby dans une AZ différente. Failover automatique en ~30 secondes en cas de panne
- **Chiffrement :** AES-256 au repos et SSL en transit
- **Backups automatiques :** 7 jours de rétention
- **Instance class :** db.t3.micro pour le portfolio (2GB RAM, 2vCPU partagés)

### Schéma de base de données

```sql
-- Partagé par les 4 microservices
CREATE DATABASE ecommerce_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- auth-service
CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,  -- bcrypt, jamais le mot de passe
  name VARCHAR(255),
  role ENUM('user', 'admin') DEFAULT 'user',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_email (email),
  INDEX idx_role (role)
);

-- product-service
CREATE TABLE products (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  price DECIMAL(10,2) NOT NULL,
  stock INT DEFAULT 0,
  category VARCHAR(100),
  image_url VARCHAR(512),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FULLTEXT idx_search (name, description)  -- recherche fulltext
);

-- order-service
CREATE TABLE orders (
  id INT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL,
  total_amount DECIMAL(10,2) NOT NULL,
  status ENUM('pending','processing','shipped','delivered','cancelled') DEFAULT 'pending',
  shipping_address TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE order_items (
  id INT PRIMARY KEY AUTO_INCREMENT,
  order_id INT NOT NULL,
  product_id INT NOT NULL,
  quantity INT NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,  -- prix figé au moment de la commande
  FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);

-- review-service
CREATE TABLE reviews (
  id INT PRIMARY KEY AUTO_INCREMENT,
  product_id INT NOT NULL,
  user_id INT NOT NULL,
  rating TINYINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_user_product (user_id, product_id),  -- contrainte 1 avis max
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

### Configuration MySQL 8.0

| Paramètre | Valeur |
|-----------|--------|
| Engine | MySQL 8.0.35 |
| Instance class | db.t3.micro |
| Storage | 20 GB |
| Multi-AZ | Oui (standby en eu-west-1b) |
| Chiffrement | AES-256 (at rest) |
| SSL en transit | Oui |
| Backups automatiques | 7 jours |
| Fenêtre de backup | 02:00-03:00 UTC |
| Fenêtre de maintenance | Lundi 04:00-05:00 UTC |
| Deletion protection | Désactivée en dev |
| Enhanced Monitoring | Désactivé en dev |

### Connexion depuis les microservices

```javascript
// src/config/database.js (identique dans les 4 services)
const mysql = require('mysql2/promise');

const pool = mysql.createPool({
  host: process.env.DB_HOST,      // Endpoint MySQL
  port: process.env.DB_PORT,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  waitForConnections: true,
  connectionLimit: 10,
  connectTimeout: 60000,
  // SSL requis pour MySQL en production
  ssl: { rejectUnauthorized: false }
});
```

---

## 11. Registry - ECR

ECR (Elastic Container Registry) héberge les images Docker dans AWS. Les images initialement sur GHCR sont migrées ici pour bénéficier du réseau AWS privé (pas de frais d'egress entre ECR et EKS dans la même région).

### Repositories créés

| Repository | Image source | Tag |
|-----------|-------------|-----|
| ecommerce/auth-service | ghcr.io/yaraportfolio/auth-service | v3.3 → migré |
| ecommerce/product-service | ghcr.io/yaraportfolio/product-service | v3.3 → migré |
| ecommerce/order-service | ghcr.io/yaraportfolio/order-service | v3.3 → migré |
| ecommerce/review-service | ghcr.io/yaraportfolio/review-service | v3.3 → migré |
| ecommerce/frontend | build local | latest |

### Politique de lifecycle

Pour éviter l'accumulation d'images, une lifecycle policy conserve les 10 dernières images par repository et expire les autres.

### Accès des nodes EKS

Les nodes EKS ont le rôle IAM `ecommerce-eks-node-role` avec la policy `AmazonEC2ContainerRegistryReadOnly`. Ils peuvent puller les images sans credentials explicites - l'authentification se fait via le rôle IAM attaché à l'instance.

### Scan de sécurité

Chaque push déclenche un scan automatique via Amazon ECR Image Scanning (basé sur Clair). Les CVE critiques et élevées sont visibles dans la console ECR → Findings. En CI/CD, ce scan peut être intégré pour bloquer le déploiement en cas de vulnérabilité critique.

---

## 12. Secrets & IAM

### AWS Secrets Manager

Deux secrets sont stockés dans Secrets Manager :

**`ecommerce/db/credentials`**
```json
{
  "username": "devops_user",
  "password": "VotreMotDePasse",
  "host": "cluster-xxx.eu-west-1.rds.amazonaws.com",
  "port": 3306,
  "dbname": "ecommerce_db"
}
```

**`ecommerce/jwt/secret`**
```
VotreJwtSecretSuperSécuriséMin32Chars
```

Les secrets sont consommés de deux façons selon la couche :
- **EKS / Kubernetes :** les secrets sont récupérés lors du déploiement Helm et injectés en tant que `kubectl Secret` dans le namespace `ecommerce`. Les pods les consomment via des variables d'environnement
- **EC2 / Beanstalk :** les User Data scripts ou les variables d'environnement Beanstalk contiennent les valeurs (passées via Terraform `set_sensitive` ou console AWS)

### Rôles IAM

**`ecommerce-eks-cluster-role`** - rôle du control plane EKS  
Policy : `AmazonEKSClusterPolicy`

**`ecommerce-eks-node-role`** - rôle des nodes EC2 dans le node group  
Policies : `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`

**`ecommerce-frontend-ec2-role`** - rôle des instances frontend EC2  
Policies : `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`

**`AmazonEKSLoadBalancerControllerRole`** - rôle du AWS Load Balancer Controller  
Policy custom : `AWSLoadBalancerControllerIAMPolicy` (permet de créer/modifier/supprimer des ALB et Target Groups)

### Principe du moindre privilège

Chaque rôle n'a que les permissions strictement nécessaires. Les nodes EKS n'ont pas accès à S3, RDS, ou Secrets Manager directement - ils accèdent à la DB via les variables d'environnement injectées par les secrets Kubernetes. Cela limite l'impact d'une compromission d'un node.

---

## 13. Observabilité

### CloudWatch Logs

Chaque composant envoie ses logs vers CloudWatch Logs dans des log groups dédiés :

| Log group | Source | Rétention |
|-----------|--------|----------|
| `/aws/eks/ecommerce-cluster/cluster` | Control plane EKS | 7 jours |
| `/ecs/ecommerce-frontend` | Tasks ECS Fargate | 7 jours |
| `/aws/rds/cluster/ecommerce-aurora-cluster` | Aurora slow queries | 7 jours |

Pour les pods EKS, les logs sont collectés via Fluent Bit (déployable comme DaemonSet) ou via CloudWatch Container Insights.

### CloudWatch Metrics

Métriques automatiques disponibles sans configuration :

| Namespace | Métriques clés |
|-----------|---------------|
| `AWS/ApplicationELB` | RequestCount, TargetResponseTime, HTTPCode_Target_5XX |
| `AWS/EKS` | cluster_node_count, cluster_failed_node_count |
| `AWS/RDS` | DatabaseConnections, CPUUtilization, FreeableMemory |
| `ContainerInsights` | pod_cpu_utilization, pod_memory_utilization |

### Prometheus (intégré aux microservices)

Chaque microservice expose `/metrics` au format Prometheus. Les métriques applicatives (requêtes HTTP, latences, erreurs) sont disponibles indépendamment de l'infrastructure.

Si le Prometheus Operator est déployé sur EKS, les `ServiceMonitor` du Helm chart activent le scraping automatique. Les dashboards Grafana pré-configurés affichent les métriques RED (Rate, Errors, Duration) par service.

### CloudTrail

CloudTrail enregistre toutes les appels d'API AWS dans la région : qui a créé quoi, quand, depuis quelle IP. C'est l'audit log de l'infrastructure. Activé par défaut, logs vers S3.

### VPC Flow Logs

Les VPC Flow Logs capturent les métadonnées de chaque connexion réseau dans le VPC (IP source, IP dest, port, octets, accept/reject). Utile pour déboguer des problèmes de Security Group ou détecter du trafic anormal. Stockage vers S3 ou CloudWatch Logs.

---

## 14. Flux de données complet

### Scénario : un utilisateur consulte la liste des produits

```
1. Navigateur → https://ecommerce.votredomaine.com/products
   Route 53 résout le domaine vers CloudFront

2. CloudFront → cherche la page en cache
   Cache MISS → forward vers ALB public

3. ALB public (ecommerce-alb-pub)
   → Listener HTTPS :443
   → Forward vers Target Group ecommerce-tg-frontend
   → Choisit une instance frontend healthy (round-robin)

4. Instance frontend (EC2 / Beanstalk / ECS)
   → NGINX reçoit GET /products
   → Sert le fichier dist/index.html (SPA React)
   → Le navigateur charge la page

5. React (dans le navigateur) → fetch('/api/products')
   → NGINX reçoit GET /api/products
   → proxy_pass vers http://ALB_INTERNE_EKS/api/products

6. ALB interne EKS
   → Route /api/products vers le service Kubernetes product-service
   → Choisit un pod healthy (round-robin kube-proxy)

7. Pod product-service (:3002)
   → Reçoit GET /api/products
   → Pas d'auth requise (route publique)
   → mysql2 → connexion pool vers writer endpoint Aurora

8. RDS MySQL
   → SELECT * FROM products ORDER BY created_at DESC
   → Retourne les résultats

9. Remontée des réponses dans l'ordre inverse
   Aurora → product-service → ALB interne → NGINX → ALB public → CloudFront → Navigateur
```

### Scénario : un utilisateur passe une commande

```
1. Navigateur → POST /api/orders avec JWT dans Authorization header
   (le JWT a été obtenu lors du login via auth-service)

2-5. Même chemin que ci-dessus jusqu'à NGINX
   → proxy_pass vers ALB interne → order-service

6. Pod order-service (:3003)
   → Middleware authMiddleware.js vérifie le JWT
   → jwt.verify(token, process.env.JWT_SECRET)
   → JWT valide → user_id extrait du payload

   Note : order-service ne contacte PAS auth-service pour vérifier le JWT
   Tous les services partagent le même JWT_SECRET et vérifient eux-mêmes
   C'est un choix d'architecture "shared secret" vs "introspection"

   → INSERT INTO orders (user_id, total_amount, status, ...) VALUES (...)
   → INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (...)
   → Retourne la commande créée avec son ID

7. Réponse 201 Created remonte jusqu'au navigateur
```

---

## 15. Correspondances OCI → AWS

| Concept OCI | Équivalent AWS | Différences notables |
|-------------|---------------|---------------------|
| VCN (Virtual Cloud Network) | VPC | OCI VCN est régional, subnets peuvent être régionaux ou AD-specific. AWS VPC régional, subnets zonaux (AZ) |
| Security List | Security Group | Security Lists OCI stateless/stateful. Security Groups AWS stateful (réponse automatique) |
| NSG (Network Security Group) | Security Group | Très similaires, AWS SGs s'attachent à l'ENI |
| Compartment | - | Pas d'équivalent direct. AWS utilise les comptes, Organizations et tags pour l'isolation |
| Internet Gateway | Internet Gateway | Identique dans le principe |
| NAT Gateway | NAT Gateway | Identique. OCI : pas de frais d'egress sur les 10 premiers TB/mois. AWS : $0.045/GB |
| OKE (Oracle Kubernetes Engine) | EKS | OKE nodes peuvent être dans des subnets publics ou privés. EKS recommande privés uniquement |
| Load Balancer OCI (stateful) | ALB | ALB opère en L7 uniquement. OCI LB supporte L4+L7 dans la même ressource |
| OCR (Oracle Container Registry) | ECR | ECR a le scan de vulnérabilités intégré (payant au-delà du Free Tier) |
| Autonomous Database / DBCS | RDS MySQL | MySQL 8.0 compatible MariaDB 10.11. Schéma et drivers inchangés |
| Resource Manager (Terraform natif) | - / Terraform | AWS n'a pas de Terraform natif. CloudFormation est l'IaC natif AWS, Terraform reste populaire |
| OCI Vault | Secrets Manager | Secrets Manager peut faire la rotation automatique des credentials RDS |
| OCI Monitoring | CloudWatch | CloudWatch combine métriques, logs, traces (vs services séparés sur OCI) |
| OCI Functions | Lambda | Lambda est plus mature, intégration plus profonde avec l'écosystème AWS |
| Flex Shapes (OCPU libres) | - | Pas d'équivalent AWS. EC2 a des familles fixes (t3, m6i, c6i...). GCP a les custom machine types |

---

## 16. Décisions d'architecture

### Pourquoi un ALB interne entre le frontend et EKS ?

Le frontend ne contacte pas directement les pods Kubernetes. L'ALB interne créé par le AWS Load Balancer Controller sert de couche d'indirection qui :
- Fait le health checking des pods et retire les pods qui ne répondent pas
- Permet le rolling update des microservices sans coupure côté frontend
- Isole le frontend du routage Kubernetes (le frontend n'a pas besoin de connaître les IPs des pods)

### Pourquoi partager la même base de données pour 4 microservices ?

En architecture microservices stricte, chaque service devrait avoir sa propre base de données. Ici, le choix de partager `ecommerce_db` est délibéré pour deux raisons :

D'abord, l'origine du projet : l'application a été conçue initialement en monolithe puis décomposée en microservices avec un `ecommerce-backend` commun. La DB partagée est un héritage de cette évolution.

Ensuite, la simplicité opérationnelle : une seule instance Aurora à gérer, sauvegarder, et monitorer. Pour un portfolio DevOps, ce choix permet de se concentrer sur l'orchestration Kubernetes plutôt que sur la complexité des transactions distribuées.

La séparation des bases (pattern Database per Service) serait l'évolution naturelle pour une production à forte charge.

### Pourquoi trois options de frontend ?

L'objectif pédagogique du projet est de comprendre la progression naturelle des architectures AWS : VM classique (EC2) → PaaS (Beanstalk) → Serverless containers (ECS Fargate). Les trois déploient exactement la même image Docker - seul le mécanisme d'orchestration change. C'est le meilleur moyen de comprendre les trade-offs de chaque approche.

### Pourquoi EKS pour les microservices et pas ECS ?

EKS a été choisi parce que le projet utilise déjà un Helm chart Kubernetes (`ecommerce-k8s-helm`) avec des Deployments, Services, HPAs, et Ingress configurés. Migrer ce chart sur EKS est direct - même Helm, même YAML. Réécrire en Task Definitions ECS aurait demandé un effort significatif sans bénéfice pédagogique.

### JWT secret partagé vs introspection

Les quatre microservices partagent le même `JWT_SECRET`. Chacun valide lui-même les tokens reçus sans appeler auth-service. C'est l'approche "shared secret" :

**Avantage :** aucune dépendance réseau pour la validation - si auth-service est down, les utilisateurs déjà connectés continuent à fonctionner.

**Inconvénient :** impossible de révoquer un token avant son expiration (24h). En cas de vol de token, l'attaquant a 24h.

L'alternative serait un service d'introspection centralisé ou des tokens de courte durée (5-15 min) avec refresh tokens.

---

## 17. Estimations de coûts

Estimation pour un usage modéré en `eu-west-1`, hors Free Tier.

### Coûts fixes mensuels

| Service | Détail | Coût/mois |
|---------|--------|-----------|
| EKS Cluster | Control plane | ~$73 |
| EC2 Nodes EKS | 3 × t3.medium On-Demand | ~$90 |
| RDS MySQL | 1 instance db.t3.micro | ~$15 |
| NAT Gateway | 2 × ($0.045/h × 730h) | ~$66 |
| ALB public | ~$16 + $0.008/LCU | ~$20 |
| ECR | 5 repos, ~5 GB images | ~$5 |
| Secrets Manager | 2 secrets | ~$1 |
| Route 53 | 1 hosted zone | ~$1 |

### Coûts variables

| Service | Détail | Estimation |
|---------|--------|-----------|
| CloudFront | 1 TB de données servies | ~$9 |
| NAT Gateway trafic | 10 GB (pulls ECR, AWS SDK) | ~$0.45 |
| RDS MySQL storage | ~20 GB × $0.12 | ~$2.4 |
| CloudWatch Logs | 5 GB ingested | ~$2.5 |

### Total estimé

| Mode | Coût/mois |
|------|----------|
| Infrastructure de base (sans frontend EC2) | ~$324 |
| + Option A : EC2 ASG (2 × t3.medium) | +$60 → **~$384** |
| + Option B : Beanstalk (2 × t3.medium géré) | +$60 → **~$384** |
| + Option C : ECS Fargate (2 tasks 0.25vCPU) | +$12 → **~$336** |

### Optimisations pour réduire les coûts en développement

- Réduire à **1 seul NAT Gateway** : économie de $33/mois (perte de résilience AZ)
- Utiliser des **instances Spot** pour les nodes EKS : réduction de 60-70% sur les nodes
- Passer les instances Aurora et EC2 en **t3.small** : économie de ~40%
- Éteindre le cluster EKS la nuit (script `eksctl scale nodegroup --nodes=0`) : économie proportionnelle aux heures d'inactivité

---

*Ce document décrit l'état de l'architecture à la date de rédaction. Pour le guide de déploiement par la console AWS, voir [GUIDE-CONSOLE-AWS.md](./GUIDE-CONSOLE-AWS.md). Pour le guide en ligne de commande, voir [GUIDE-DEPLOIEMENT-MANUEL.md](./GUIDE-DEPLOIEMENT-MANUEL.md). Pour l'IaC Terraform, voir [../terraform/](../terraform/).*
