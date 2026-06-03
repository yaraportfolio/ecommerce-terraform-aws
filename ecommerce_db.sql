-- ============================================
-- E-COMMERCE DATABASE - MariaDB 10.11+
-- ============================================
-- Script de création de la base de données pour la plateforme e-commerce
-- Compatible : MariaDB 10.11+ / MySQL 8.0+
-- Version : 1.0
-- Date : 2026-01-02
-- ============================================

-- Créer la base de données
DROP DATABASE IF EXISTS ecommerce_db;
CREATE DATABASE ecommerce_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ecommerce_db;

-- ============================================
-- TABLE: users
-- ============================================
-- Stocke les utilisateurs (clients et administrateurs)
CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(255) UNIQUE NOT NULL COMMENT 'Email unique de l\'utilisateur',
  password_hash VARCHAR(255) NOT NULL COMMENT 'Mot de passe hashé avec bcrypt',
  name VARCHAR(255) COMMENT 'Nom complet de l\'utilisateur',
  role ENUM('user', 'admin') DEFAULT 'user' COMMENT 'Rôle: user (client) ou admin',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Date de création du compte',
  INDEX idx_email (email),
  INDEX idx_role (role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Table des utilisateurs';

-- ============================================
-- TABLE: products
-- ============================================
-- Catalogue de produits avec catégories et stock
CREATE TABLE products (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(255) NOT NULL COMMENT 'Nom du produit',
  description TEXT COMMENT 'Description détaillée',
  price DECIMAL(10,2) NOT NULL COMMENT 'Prix en euros',
  stock INT DEFAULT 0 COMMENT 'Quantité en stock',
  category VARCHAR(100) COMMENT 'Catégorie du produit',
  image_url VARCHAR(512) COMMENT 'URL de l\'image du produit',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Date d\'ajout',
  CONSTRAINT chk_price CHECK (price >= 0),
  CONSTRAINT chk_stock CHECK (stock >= 0),
  INDEX idx_category (category),
  INDEX idx_price (price),
  FULLTEXT idx_search (name, description)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Catalogue de produits';

-- ============================================
-- TABLE: orders
-- ============================================
-- Commandes des utilisateurs
CREATE TABLE orders (
  id INT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL COMMENT 'Référence vers l\'utilisateur',
  total_amount DECIMAL(10,2) NOT NULL COMMENT 'Montant total de la commande',
  status ENUM('pending', 'processing', 'shipped', 'delivered', 'cancelled') DEFAULT 'pending' COMMENT 'Statut de la commande',
  shipping_address TEXT COMMENT 'Adresse de livraison',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Date de la commande',
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Dernière mise à jour',
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  INDEX idx_user_id (user_id),
  INDEX idx_status (status),
  INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Commandes clients';

-- ============================================
-- TABLE: order_items
-- ============================================
-- Détails des articles dans chaque commande
CREATE TABLE order_items (
  id INT PRIMARY KEY AUTO_INCREMENT,
  order_id INT NOT NULL COMMENT 'Référence vers la commande',
  product_id INT NOT NULL COMMENT 'Référence vers le produit',
  quantity INT NOT NULL COMMENT 'Quantité commandée',
  unit_price DECIMAL(10,2) NOT NULL COMMENT 'Prix unitaire au moment de la commande',
  FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
  CONSTRAINT chk_quantity CHECK (quantity > 0),
  INDEX idx_order_id (order_id),
  INDEX idx_product_id (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Détails des commandes';

-- ============================================
-- TABLE: reviews
-- ============================================
-- Avis et notes des produits
CREATE TABLE reviews (
  id INT PRIMARY KEY AUTO_INCREMENT,
  product_id INT NOT NULL COMMENT 'Référence vers le produit',
  user_id INT NOT NULL COMMENT 'Référence vers l\'utilisateur',
  rating INT NOT NULL COMMENT 'Note de 1 à 5 étoiles',
  comment TEXT COMMENT 'Commentaire de l\'utilisateur',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Date de l\'avis',
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Dernière modification',
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE KEY unique_review (product_id, user_id) COMMENT 'Un seul avis par utilisateur par produit',
  CONSTRAINT chk_rating CHECK (rating >= 1 AND rating <= 5),
  INDEX idx_product_id (product_id),
  INDEX idx_user_id (user_id),
  INDEX idx_rating (rating)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Avis clients sur les produits';

-- ============================================
-- DONNÉES DE TEST - USERS
-- ============================================
INSERT INTO users (email, password_hash, name, role) VALUES
-- Admin (mot de passe: admin123)
('admin@ecommerce.com', '$2b$10$9o/1YrgIriD7S8359w4bKuEU2uiq12wOebshapMnjzGs4I/a38/AS', 'Administrateur', 'admin'),

-- Users (mot de passe: password123)
('john.doe@example.com', '$2b$10$FQad4vOXtoELbYiRdWnycOBng/AQ4105imZxr8HxEkyxvojUUJsC.', 'John Doe', 'user'),
('jane.smith@example.com', '$2b$10$FQad4vOXtoELbYiRdWnycOBng/AQ4105imZxr8HxEkyxvojUUJsC.', 'Jane Smith', 'user'),
('alice.martin@example.com', '$2b$10$FQad4vOXtoELbYiRdWnycOBng/AQ4105imZxr8HxEkyxvojUUJsC.', 'Alice Martin', 'user');

-- ============================================
-- DONNÉES DE TEST - PRODUCTS
-- ============================================
INSERT INTO products (name, description, price, stock, category, image_url) VALUES
-- ELECTRONICS
('iPhone 15 Pro', 'Smartphone Apple dernière génération avec puce A17 Pro, caméra 48MP, écran ProMotion 120Hz, 256GB de stockage', 1199.99, 3, 'Electronics', 
 'https://images.unsplash.com/photo-1695048133142-1a20484d2569?w=500&auto=format&fit=crop'),

('Samsung Galaxy S24 Ultra', 'Smartphone Samsung flagship avec Snapdragon 8 Gen 3, écran AMOLED 6.8", S Pen intégré, 512GB', 1099.99, 45, 'Electronics', 
 'https://images.unsplash.com/photo-1610945415295-d9bbf067e59c?w=500&auto=format&fit=crop'),

('MacBook Pro M3 16"', 'Ordinateur portable Apple avec puce M3 Pro, 16GB RAM, 512GB SSD, écran Liquid Retina XDR', 2499.99, 30, 'Electronics', 
 'https://images.unsplash.com/photo-1517336714731-489689fd1ca8?w=500&auto=format&fit=crop'),

('Dell XPS 15', 'Laptop professionnel Intel Core i7-13700H, 16GB RAM, RTX 4050, écran OLED 15.6" 4K', 1899.99, 25, 'Electronics', 
 'https://images.unsplash.com/photo-1593642632823-8f785ba67e45?w=500&auto=format&fit=crop'),

('Sony WH-1000XM5', 'Casque audio sans fil avec réduction de bruit active, autonomie 30h, Bluetooth multipoint', 399.99, 60, 'Electronics', 
 'https://images.unsplash.com/photo-1505740420928-5e560c06d30e?w=500&auto=format&fit=crop'),

('iPad Air M2', 'Tablette Apple avec puce M2, écran Liquid Retina 10.9", Apple Pencil compatible, 256GB', 749.99, 40, 'Electronics', 
 'https://images.unsplash.com/photo-1544244015-0df4b3ffc6b0?w=500&auto=format&fit=crop'),

-- BOOKS
('Clean Code', 'Robert C. Martin - Le guide de référence pour écrire du code propre et maintenable, bonnes pratiques de programmation', 45.99, 5, 'Books', 
 'https://images.unsplash.com/photo-1532012197267-da84d127e765?w=500&auto=format&fit=crop'),

('The DevOps Handbook', 'Gene Kim, Jez Humble - Guide complet des pratiques DevOps, CI/CD, automatisation et culture collaborative', 49.99, 80, 'Books', 
 'https://images.unsplash.com/photo-1544947950-fa07a98d237f?w=500&auto=format&fit=crop'),

('Designing Data-Intensive Applications', 'Martin Kleppmann - Architecture des systèmes distribués, bases de données, streaming de données', 54.99, 70, 'Books', 
 'https://images.unsplash.com/photo-1495446815901-a7297e633e8d?w=500&auto=format&fit=crop'),

-- CLOTHING
('Nike Air Max 2024', 'Chaussures de sport unisexe avec amorti Air Max, semelle en mousse, design moderne et confortable', 159.99, 4, 'Clothing', 
 'https://images.unsplash.com/photo-1542291026-7eec264c27ff?w=500&auto=format&fit=crop'),

('Levi''s 501 Original Jeans', 'Jean classique coupe droite, denim 100% coton, le modèle iconique depuis 1873, disponible en plusieurs tailles', 89.99, 150, 'Clothing', 
 'https://images.unsplash.com/photo-1542272604-787c3835535d?w=500&auto=format&fit=crop'),

('North Face Jacket', 'Veste imperméable coupe-vent pour randonnée, membrane Gore-Tex, capuche ajustable, poches multiples', 249.99, 75, 'Clothing', 
 'https://images.unsplash.com/photo-1551028719-00167b16eac5?w=500&auto=format&fit=crop'),

-- HOME
('Dyson V15 Detect', 'Aspirateur sans fil intelligent avec laser de détection de poussière, autonomie 60min, filtration HEPA', 699.99, 40, 'Home', 
 'https://images.unsplash.com/photo-1558317374-067fb5f30001?w=500&auto=format&fit=crop'),

('KitchenAid Artisan', 'Robot pâtissier professionnel 4.8L, 10 vitesses, bol en inox, accessoires inclus, 300W de puissance', 449.99, 4, 'Home', 
 'https://images.unsplash.com/photo-1570222094114-d054a817e56b?w=500&auto=format&fit=crop'),

('Philips Hue Starter Kit', 'Kit d''éclairage connecté avec 3 ampoules LED E27, pont Hue, contrôle via app, compatible Alexa/Google', 129.99, 90, 'Home', 
 'https://images.unsplash.com/photo-1558089687-f282ffcbc126?w=500&auto=format&fit=crop');

-- ============================================
-- DONNÉES DE TEST - ORDERS
-- ============================================
INSERT INTO orders (user_id, total_amount, status, shipping_address) VALUES
(2, 1599.98, 'delivered', '01 BP 123 Abidjan Plateau, Côte d’Ivoire'),
(2, 749.99, 'shipped', 'Rue des Jardins, Cocody, Abidjan, Côte d’Ivoire'),
(3, 945.97, 'processing', 'Boulevard de Marseille, Zone 4, Abidjan, Côte d’Ivoire'),
(4, 249.99, 'pending', 'Avenue Terrasson de Fougères, Treichville, Abidjan, Côte d’Ivoire');

-- ============================================
-- DONNÉES DE TEST - ORDER_ITEMS
-- ============================================
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
-- Order 1 (John Doe - delivered)
(1, 1, 1, 1199.99),  -- iPhone 15 Pro
(1, 5, 1, 399.99),   -- Sony WH-1000XM5

-- Order 2 (John Doe - shipped)
(2, 6, 1, 749.99),   -- iPad Air M2

-- Order 3 (Jane Smith - processing)
(3, 7, 1, 45.99),    -- Clean Code
(3, 8, 1, 49.99),    -- DevOps Handbook
(3, 10, 1, 159.99),  -- Nike Air Max
(3, 13, 1, 699.99),  -- Dyson V15

-- Order 4 (Alice Martin - pending)
(4, 12, 1, 249.99);  -- North Face Jacket

-- ============================================
-- DONNÉES DE TEST - REVIEWS
-- ============================================
INSERT INTO reviews (product_id, user_id, rating, comment) VALUES
-- Electronics
(1, 2, 5, 'Excellent smartphone ! La caméra est incroyable et la performance est au top. Je recommande vivement.'),
(1, 3, 4, 'Très bon téléphone mais un peu cher. La qualité Apple est toujours au rendez-vous.'),
(3, 2, 5, 'Le meilleur laptop que j''ai jamais eu. La puce M3 est ultra rapide, parfait pour le développement.'),
(5, 3, 5, 'Qualité sonore exceptionnelle, réduction de bruit active très efficace. Confortable pour de longues sessions.'),

-- Books
(7, 2, 5, 'Un must-read pour tout développeur. Ce livre a transformé ma façon de coder. Incontournable !'),
(8, 4, 4, 'Très instructif sur les pratiques DevOps. Quelques exemples un peu datés mais les concepts restent valables.'),

-- Clothing
(10, 3, 4, 'Chaussures confortables et stylées. Bon rapport qualité-prix, parfaites pour le quotidien.'),

-- Home
(13, 2, 5, 'Aspirateur incroyable ! Le laser permet de voir toute la poussière. Plus jamais sans !');

-- ============================================
-- CRÉATION DES UTILISATEURS APPLICATIFS
-- ============================================
-- ⚠️ NOTE: Utilisateurs créés via RDS Master User (devops_user)
-- Les lignes CREATE USER ci-dessous sont commentées car l'utilisateur existe déjà
-- Décommenter si vous utilisez un autre utilisateur root pour l'import

-- -- Utilisateur pour les microservices
-- DROP USER IF EXISTS 'devops_user'@'%';
-- CREATE USER 'devops_user'@'%' IDENTIFIED BY 'devops_password';
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ecommerce_db.* TO 'devops_user'@'%';

-- -- Utilisateur en lecture seule (monitoring/analytics)
-- DROP USER IF EXISTS 'readonly_user'@'%';
-- CREATE USER 'readonly_user'@'%' IDENTIFIED BY 'readonly_password';
-- GRANT SELECT ON ecommerce_db.* TO 'readonly_user'@'%';

-- -- Utilisateur admin (backup/maintenance)
-- DROP USER IF EXISTS 'admin_user'@'%';
-- CREATE USER 'admin_user'@'%' IDENTIFIED BY 'admin_password';
-- GRANT ALL PRIVILEGES ON ecommerce_db.* TO 'admin_user'@'%';

-- FLUSH PRIVILEGES;

-- ============================================
-- VÉRIFICATION DE L'INSTALLATION
-- ============================================
SELECT '============================================' AS '';
SELECT 'E-COMMERCE DATABASE - INSTALLATION COMPLETE' AS '';
SELECT '============================================' AS '';
SELECT '' AS '';

-- Compter les enregistrements
SELECT 'TABLES:' AS '', COUNT(*) AS total FROM information_schema.tables WHERE table_schema = 'ecommerce_db';
SELECT 'Users:' AS '', COUNT(*) AS total FROM users;
SELECT 'Products:' AS '', COUNT(*) AS total FROM products;
SELECT 'Orders:' AS '', COUNT(*) AS total FROM orders;
SELECT 'Order Items:' AS '', COUNT(*) AS total FROM order_items;
SELECT 'Reviews:' AS '', COUNT(*) AS total FROM reviews;

SELECT '' AS '';
SELECT 'USERS APPLICATIFS:' AS '';
SELECT User, Host FROM mysql.user WHERE User IN ('devops_user', 'readonly_user', 'admin_user');

SELECT '' AS '';
SELECT '✅ Installation réussie !' AS '';
SELECT 'Database: ecommerce_db' AS '';
SELECT 'Version: 1.0' AS '';
SELECT 'Date: 2026-01-02' AS '';
