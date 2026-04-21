# Réponses Bonus - Jour 1

### 1. Tableau de bord Traefik
* **Risque de sécurité :** L'activation sans protection expose toute la configuration du cluster (routes, services, IPs internes) à des utilisateurs non autorisés.
* **Atténuation :** Utiliser un middleware Traefik de type **BasicAuth** pour imposer une authentification par mot de passe.

### 2. Manuel TLS
* **Format secret :** Le type `kubernetes.io/tls` stocke le certificat public (`tls.crt`) et la clé privée (`tls.key`).
* **Fonctionnement :** Ce duo permet à l'Ingress Controller de déchiffrer le flux HTTPS (terminaison TLS) avant de renvoyer le trafic vers le service en HTTP.

### 3. Limites de ressources
* **Observation :** À **10Mi**, le pod reste en statut `Pending` ou `OOMKilled`.
* **Pourquoi ?** Traefik nécessite un pic de RAM au démarrage pour charger son binaire et indexer les ressources Kubernetes. 10Mi est inférieur au seuil minimal vital de l'application.

### 4. Sensibilisation multi-nœuds
* **Observation :** Les répliques sont réparties sur les nœuds `worker` et `worker2`.
* **Pourquoi Traefik les trouve ?** Traefik communique avec le **Service** Kubernetes (IP stable). Le réseau du cluster (**CNI**) se charge de router le trafic vers les pods, peu importe le nœud sur lequel ils résident physiquement.
