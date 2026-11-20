# Règles d'alerte — Prometheus-bundle

> Document généré à partir de `prometheus-bundle.sh` (valeurs de seuil par défaut).
> Les seuils se modifient avec `./prometheus-bundle.sh 02 definir SEUIL_... <valeur>`, puis s'appliquent automatiquement.
> Liste en ligne de commande : `./prometheus-bundle.sh 02 regles [application]`.

Les règles d'une application ne sont déployées que lorsqu'au moins une cible de cette application est déclarée (`03 cible`).

**Gravités** : 🔴 critique = intervention immédiate (astreinte) · 🟠 avertissement = à traiter dans la journée · 🔵 info = information, non envoyée par défaut.

**Délai** : durée pendant laquelle la condition doit rester vraie avant l'envoi (évite les fausses alertes sur un pic ponctuel).

**132 règles** au total, réparties ainsi :

- [Supervision elle-même (toujours active)](#base) — 10 règles
- [Serveurs Linux — agent `linux`](#linux) — 21 règles
- [Serveurs Windows — `windows`](#windows) — 6 règles
- [Sites web, ports TCP et ping — `http`, `tcp`, `icmp`](#sondes) — 8 règles
- [MySQL / MariaDB — `mysql`](#mysql) — 10 règles
- [PostgreSQL — `postgresql`](#postgresql) — 9 règles
- [Redis — `redis`](#redis) — 9 règles
- [MongoDB — `mongodb`](#mongodb) — 5 règles
- [Memcached — `memcached`](#memcached) — 4 règles
- [Elasticsearch / OpenSearch — `elasticsearch`](#elasticsearch) — 7 règles
- [Nginx — `nginx`](#nginx) — 3 règles
- [Apache httpd — `apache`](#apache) — 3 règles
- [PHP-FPM — `phpfpm`](#phpfpm) — 4 règles
- [HAProxy — `haproxy`](#haproxy) — 4 règles
- [RabbitMQ — `rabbitmq`](#rabbitmq) — 6 règles
- [Kafka — `kafka`](#kafka) — 4 règles
- [Java / JVM et Spring Boot — `jvm`, `springboot`](#jvm) — 7 règles
- [Processus — `process`](#process) — 5 règles
- [Conteneurs Docker (cAdvisor) — `docker`](#docker) — 4 règles
- [Applications instrumentées — `application`](#application) — 3 règles

<a id="base"></a>
## Supervision elle-même (toujours active)

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `CibleInjoignable` | 🔴 critique | 2m | <job> injoignable sur <instance> — Prometheus ne parvient plus à collecter <instance> (job <job>) depuis 2 minutes : service, agent ou réseau en panne. |
| `MajoriteCiblesInjoignables` | 🔴 critique | 5m | Plus de la moitié des cibles du job <job> sont injoignables — <valeur> des cibles du job <job> ne répondent plus : incident réseau ou panne générale probable. |
| `PrometheusConfigurationInvalide` | 🟠 avertissement | 5m | Échec du rechargement de la configuration Prometheus — La dernière configuration n'a pas été chargée sur <instance>. Vérifier avec : promtool check config. |
| `PrometheusAlertmanagerDeconnecte` | 🔴 critique | 5m | Prometheus n'est connecté à aucun Alertmanager — Aucune alerte ne peut être envoyée depuis <instance>. |
| `PrometheusEchecEnvoiAlertes` | 🔴 critique | 5m | Prometheus n'arrive pas à transmettre les alertes — Erreurs d'envoi vers Alertmanager <alertmanager>. |
| `PrometheusEchecEvaluationRegles` | 🟠 avertissement | 0m | Des règles d'alerte échouent à l'évaluation — Groupe <rule_group> : <valeur> échecs en 10 min. |
| `PrometheusEchecCompactionTSDB` | 🟠 avertissement | immédiat | Échec de compaction de la base Prometheus — La base de données de <instance> rencontre des erreurs : vérifier l'espace disque. |
| `AlertmanagerConfigurationInvalide` | 🟠 avertissement | 5m | Échec du rechargement de la configuration Alertmanager — Vérifier avec : amtool check-config. |
| `AlertmanagerEchecNotifications` | 🔴 critique | 5m | Le canal <integration> n'envoie plus les alertes — Alertmanager échoue à notifier via <integration> : jeton expiré, URL modifiée ou service tiers indisponible. |
| `Watchdog` | — | immédiat | Alerte de contrôle toujours active (chaîne d'alerte opérationnelle) — Cette alerte est volontairement toujours active. Elle n'est envoyée à aucun canal. |

<a id="linux"></a>
## Serveurs Linux — agent `linux`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `HoteCPUSature` | 🟠 avertissement | 15m | CPU à <valeur> % sur <instance> — Utilisation CPU supérieure à 85 % depuis 15 minutes. |
| `HoteCPUCritique` | 🔴 critique | 10m | CPU saturé (<valeur> %) sur <instance> — Utilisation CPU supérieure à 95 % depuis 10 minutes : les applications sont ralenties. |
| `HoteChargeElevee` | 🟠 avertissement | 15m | Charge système élevée sur <instance> — Charge moyenne 15 min = <valeur> par CPU (seuil 2) : processus en attente CPU ou disque. |
| `HoteIOWaitEleve` | 🟠 avertissement | 15m | Attente disque (iowait) à <valeur> % sur <instance> — Le stockage est trop lent pour la charge demandée. |
| `HoteMemoireSaturee` | 🟠 avertissement | 10m | Mémoire utilisée à <valeur> % sur <instance> — Mémoire disponible faible (seuil 85 %). |
| `HoteMemoireCritique` | 🔴 critique | 5m | Mémoire épuisée (<valeur> %) sur <instance> — Risque imminent d'arrêt de processus par le noyau (OOM killer). |
| `HoteProcessusTueOOM` | 🟠 avertissement | immédiat | Processus tué par manque de mémoire sur <instance> — Le noyau a tué <valeur> processus (OOM killer) en 15 min. Voir : journalctl -k \| grep -i oom. |
| `HoteSwapIntensif` | 🟠 avertissement | 15m | Swap utilisé à <valeur> % sur <instance> — Le serveur manque durablement de mémoire vive. |
| `HoteDisquePlein` | 🟠 avertissement | 10m | Disque <mountpoint> rempli à <valeur> % sur <instance> — Seuil d'avertissement 80 % dépassé : prévoir un nettoyage ou une extension. |
| `HoteDisqueCritique` | 🔴 critique | 5m | Disque <mountpoint> presque plein (<valeur> %) sur <instance> — Au-delà de 90 % : risque d'arrêt des applications et bases de données. |
| `HoteDisquePleinSous24h` | 🟠 avertissement | 30m | Le disque <mountpoint> sera plein dans moins de 24 h sur <instance> — Projection basée sur la tendance des 6 dernières heures. |
| `HoteInodesEpuises` | 🟠 avertissement | 10m | Inodes presque épuisés sur <mountpoint> (<instance>) — Il reste <valeur> % d'inodes : trop de petits fichiers (sessions, cache, logs). |
| `HoteDisqueLectureSeule` | 🔴 critique | 2m | Système de fichiers <mountpoint> passé en lecture seule sur <instance> — Erreur disque probable : vérifier dmesg et l'état du stockage. |
| `HoteDisqueSature` | 🟠 avertissement | 15m | Disque <device> occupé à plus de 90 % sur <instance> — Le périphérique est saturé en entrées/sorties. |
| `HoteServiceSystemdEnEchec` | 🟠 avertissement | 5m | Service <name> en échec sur <instance> — Voir : systemctl status <name> ; journalctl -u <name>. |
| `HoteRedemarre` | 🔵 info | immédiat | <instance> vient de redémarrer — Le serveur a démarré il y a moins de 10 minutes. |
| `HoteHorlogeDesynchronisee` | 🟠 avertissement | 15m | Horloge désynchronisée sur <instance> — Vérifier chrony/ntpd : une horloge fausse perturbe certificats, logs et clusters. |
| `HoteErreursReseau` | 🟠 avertissement | 10m | Erreurs réseau sur <device> (<instance>) — <valeur> erreurs/s : câble, carte ou pilote défaillant. |
| `HoteInterfaceReseauDown` | 🟠 avertissement | 5m | Interface réseau <device> inactive sur <instance> — L'interface était active dans la dernière heure et ne transmet plus. |
| `HoteTableConntrackPleine` | 🟠 avertissement | 5m | Table conntrack remplie à <valeur> sur <instance> — Au-delà de 100 % les nouvelles connexions sont rejetées. |
| `HoteDescripteursFichiers` | 🟠 avertissement | 10m | Descripteurs de fichiers à <valeur> sur <instance> — Risque d'erreurs 'Too many open files'. |

<a id="windows"></a>
## Serveurs Windows — `windows`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `WindowsCPUSature` | 🟠 avertissement | 15m | CPU à <valeur> % sur <instance> (Windows) — Utilisation CPU supérieure à 85 % depuis 15 minutes. |
| `WindowsCPUCritique` | 🔴 critique | 10m | CPU saturé sur <instance> (Windows) — Utilisation CPU supérieure à 95 % depuis 10 minutes. |
| `WindowsMemoireSaturee` | 🟠 avertissement | 10m | Mémoire utilisée à <valeur> % sur <instance> (Windows) — Seuil 85 % dépassé. |
| `WindowsDisquePlein` | 🟠 avertissement | 10m | Disque <volume> rempli à <valeur> % sur <instance> — Seuil 80 % dépassé. |
| `WindowsDisqueCritique` | 🔴 critique | 5m | Disque <volume> presque plein sur <instance> — Au-delà de 90 %. |
| `WindowsServiceAutomatiqueArrete` | 🟠 avertissement | 5m | Service Windows <name> arrêté sur <instance> — Service en démarrage automatique mais arrêté. |

<a id="sondes"></a>
## Sites web, ports TCP et ping — `http`, `tcp`, `icmp`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `SiteInaccessible` | 🔴 critique | 2m | Site <instance> inaccessible — La sonde HTTP échoue depuis 2 minutes : site arrêté, erreur HTTP, DNS ou certificat invalide. |
| `SiteErreurServeur` | 🔴 critique | 2m | Le site <instance> répond en erreur <valeur> — Erreur côté serveur applicatif. |
| `SiteLent` | 🟠 avertissement | 10m | Le site <instance> répond en <valeur> s — Temps de réponse moyen supérieur à 2 s depuis 10 minutes. |
| `CertificatExpireBientot` | 🟠 avertissement | 1h | Certificat de <instance> expire dans <valeur> jours — Renouveler le certificat TLS (seuil 21 jours). |
| `CertificatExpireImminent` | 🔴 critique | 10m | Certificat de <instance> expire dans <valeur> jours — Expiration imminente ou dépassée : les clients vont refuser la connexion. |
| `PortTCPFerme` | 🔴 critique | 2m | Port <instance> injoignable — La connexion TCP échoue depuis 2 minutes. |
| `HoteNeRepondPasAuPing` | 🔴 critique | 2m | <instance> ne répond plus au ping — Équipement éteint ou réseau coupé. |
| `PingLent` | 🟠 avertissement | 10m | Latence réseau de <valeur> ms vers <instance> — Seuil 200 ms dépassé. |

<a id="mysql"></a>
## MySQL / MariaDB — `mysql`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `MySQLArrete` | 🔴 critique | 1m | MySQL/MariaDB arrêté sur <instance> — L'agent n'arrive plus à se connecter à la base. |
| `MySQLConnexionsSaturees` | 🟠 avertissement | 5m | MySQL : <valeur> % des connexions utilisées sur <instance> — Au-delà de max_connections les clients sont refusés. |
| `MySQLConnexionsRefusees` | 🔴 critique | immédiat | MySQL refuse des connexions (max_connections atteint) sur <instance> — <valeur> connexions refusées en 5 min. |
| `MySQLThreadsActifsEleves` | 🟠 avertissement | 10m | MySQL : <valeur> requêtes simultanées sur <instance> — Plus de 50 requêtes exécutées simultanément : base surchargée ou verrous. |
| `MySQLRequetesLentes` | 🟠 avertissement | 5m | MySQL : <valeur> requêtes lentes en 5 min sur <instance> — Analyser le slow query log (index manquants, requêtes coûteuses). |
| `MySQLReplicationIOArretee` | 🔴 critique | 1m | Réplication MySQL (thread IO) arrêtée sur <instance> — Le réplica ne reçoit plus les journaux du primaire. Voir : SHOW REPLICA STATUS. |
| `MySQLReplicationSQLArretee` | 🔴 critique | 1m | Réplication MySQL (thread SQL) arrêtée sur <instance> — Une erreur bloque l'application des transactions. Voir : SHOW REPLICA STATUS. |
| `MySQLReplicationEnRetard` | 🟠 avertissement | 5m | Réplica MySQL en retard de <valeur> sur <instance> — Seuil 60 s dépassé. |
| `MySQLAttenteJournalInnoDB` | 🟠 avertissement | immédiat | InnoDB attend l'écriture de son journal sur <instance> — innodb_log_buffer_size probablement trop petit. |
| `MySQLRedemarre` | 🔵 info | immédiat | MySQL a redémarré sur <instance> — Démarré il y a <valeur>. |

<a id="postgresql"></a>
## PostgreSQL — `postgresql`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `PostgreSQLArrete` | 🔴 critique | 1m | PostgreSQL arrêté sur <instance> — L'agent n'arrive plus à se connecter à la base. |
| `PostgreSQLConnexionsSaturees` | 🟠 avertissement | 5m | PostgreSQL : <valeur> % des connexions utilisées sur <instance> — Envisager un pooler (PgBouncer) ou augmenter max_connections. |
| `PostgreSQLTransactionLongue` | 🟠 avertissement | 2m | Transaction active depuis <valeur> sur <datname> (<instance>) — Bloque le vacuum et peut verrouiller des tables. Voir pg_stat_activity. |
| `PostgreSQLTransactionInactiveOuverte` | 🟠 avertissement | 2m | Session 'idle in transaction' depuis <valeur> sur <datname> — Une application ne termine pas ses transactions (COMMIT/ROLLBACK manquant). |
| `PostgreSQLInterblocages` | 🟠 avertissement | immédiat | Interblocages (deadlocks) sur <datname> (<instance>) — <valeur> deadlocks en 5 min. |
| `PostgreSQLTauxAnnulationEleve` | 🟠 avertissement | 10m | <valeur> des transactions annulées sur <datname> — Erreurs applicatives probables. |
| `PostgreSQLCacheInefficace` | 🟠 avertissement | 30m | Taux de cache de <valeur> sur <datname> — shared_buffers insuffisant ou requêtes sans index (cible > 99 %). |
| `PostgreSQLReplicationEnRetard` | 🟠 avertissement | 5m | Réplica PostgreSQL en retard de <valeur> sur <instance> — Seuil 60 s dépassé. |
| `PostgreSQLRedemarre` | 🔵 info | immédiat | PostgreSQL a redémarré sur <instance> — Démarré il y a moins de 5 minutes. |

<a id="redis"></a>
## Redis — `redis`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `RedisArrete` | 🔴 critique | 1m | Redis arrêté sur <instance> — L'agent n'arrive plus à se connecter à Redis. |
| `RedisMemoireSaturee` | 🟠 avertissement | 5m | Redis utilise <valeur> % de maxmemory sur <instance> — Au-delà, Redis évince des clés ou refuse les écritures selon maxmemory-policy. |
| `RedisEvictions` | 🟠 avertissement | 5m | Redis évince des clés sur <instance> — <valeur> clés supprimées faute de mémoire en 5 min. |
| `RedisClientsSatures` | 🟠 avertissement | 5m | Redis : <valeur> % des clients max sur <instance> — Fuite de connexions côté application probable. |
| `RedisConnexionsRejetees` | 🔴 critique | immédiat | Redis rejette des connexions sur <instance> — <valeur> connexions rejetées en 5 min (maxclients atteint). |
| `RedisSauvegardeEchouee` | 🔴 critique | immédiat | La sauvegarde RDB de Redis a échoué sur <instance> — Redis peut refuser les écritures (stop-writes-on-bgsave-error). Vérifier disque et droits. |
| `RedisAOFEchoue` | 🟠 avertissement | immédiat | La réécriture AOF de Redis a échoué sur <instance> — Vérifier l'espace disque. |
| `RedisReplicaPerdu` | 🔴 critique | immédiat | Redis a perdu un réplica sur <instance> — Le nombre de réplicas connectés a diminué. |
| `RedisMasterInjoignable` | 🔴 critique | 1m | Le réplica Redis <instance> a perdu son maître — Lien de réplication coupé. |

<a id="mongodb"></a>
## MongoDB — `mongodb`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `MongoDBArrete` | 🔴 critique | 1m | MongoDB arrêté sur <instance> — L'agent n'arrive plus à se connecter à MongoDB. |
| `MongoDBConnexionsSaturees` | 🟠 avertissement | 5m | MongoDB : <valeur> % des connexions utilisées sur <instance> — Fuite de connexions ou pool applicatif mal dimensionné. |
| `MongoDBMembreReplicaSetKO` | 🔴 critique | 1m | Un membre du replica set <set> est en panne — Membre <member_idx> non sain vu depuis <instance>. |
| `MongoDBReplicationEnRetard` | 🟠 avertissement | 5m | Réplication MongoDB en retard de <valeur> — Membre <name> du replica set <set>. |
| `MongoDBAssertions` | 🟠 avertissement | 5m | MongoDB lève des assertions sur <instance> — Erreurs internes : consulter les logs mongod. |

<a id="memcached"></a>
## Memcached — `memcached`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `MemcachedArrete` | 🔴 critique | 1m | Memcached arrêté sur <instance> — L'agent n'arrive plus à se connecter à Memcached. |
| `MemcachedMemoireSaturee` | 🟠 avertissement | 10m | Memcached plein à <valeur> % sur <instance> — Le cache évince des éléments : augmenter -m. |
| `MemcachedEvictions` | 🟠 avertissement | 10m | Memcached évince <valeur> éléments/s sur <instance> — Cache sous-dimensionné : taux de succès en baisse. |
| `MemcachedConnexionsSaturees` | 🟠 avertissement | 5m | Memcached : <valeur> % des connexions max — Augmenter -c ou vérifier les clients. |

<a id="elasticsearch"></a>
## Elasticsearch / OpenSearch — `elasticsearch`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `ElasticsearchInjoignable` | 🔴 critique | 1m | Elasticsearch injoignable depuis <instance> — L'agent n'obtient plus l'état du cluster. |
| `ElasticsearchClusterRouge` | 🔴 critique | 2m | Cluster Elasticsearch <cluster> en état ROUGE — Des shards primaires ne sont pas alloués : données indisponibles. |
| `ElasticsearchClusterJaune` | 🟠 avertissement | 20m | Cluster Elasticsearch <cluster> en état JAUNE — Des réplicas ne sont pas alloués : plus de redondance. |
| `ElasticsearchNoeudPerdu` | 🔴 critique | 5m | Le cluster <cluster> a perdu un nœud — Il reste <valeur> nœuds. |
| `ElasticsearchShardsNonAlloues` | 🟠 avertissement | 15m | <valeur> shards non alloués dans <cluster> — Voir : GET _cluster/allocation/explain. |
| `ElasticsearchHeapSaturee` | 🟠 avertissement | 10m | Heap JVM à <valeur> % sur le nœud <name> — Risque de pauses GC longues et de disjoncteurs (circuit breakers). |
| `ElasticsearchDisqueSeuilBas` | 🟠 avertissement | 5m | Disque du nœud <name> à <valeur> % — Au-delà de 85 % (low watermark) aucun nouveau shard n'est alloué ; à 95 % les index passent en lecture seule. |

<a id="nginx"></a>
## Nginx — `nginx`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `NginxArrete` | 🔴 critique | 1m | Nginx arrêté sur <instance> — La page stub_status ne répond plus. |
| `NginxConnexionsElevees` | 🟠 avertissement | 10m | Nginx : <valeur> connexions actives sur <instance> — Seuil 1000 dépassé : pic de trafic ou backends lents. |
| `NginxConnexionsAbandonnees` | 🔴 critique | 5m | Nginx abandonne des connexions sur <instance> — worker_connections ou limite de fichiers atteinte. |

<a id="apache"></a>
## Apache httpd — `apache`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `ApacheArrete` | 🔴 critique | 1m | Apache arrêté sur <instance> — La page server-status ne répond plus. |
| `ApacheWorkersSatures` | 🟠 avertissement | 10m | Apache : <valeur> % des workers occupés sur <instance> — Augmenter MaxRequestWorkers ou vérifier les temps de réponse applicatifs. |
| `ApacheRedemarre` | 🔵 info | immédiat | Apache a redémarré sur <instance> — Démarré il y a moins de 5 minutes. |

<a id="phpfpm"></a>
## PHP-FPM — `phpfpm`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `PHPFPMArrete` | 🔴 critique | 1m | PHP-FPM injoignable sur <instance> — La page de statut du pool <pool> ne répond plus. |
| `PHPFPMPoolSature` | 🟠 avertissement | immédiat | Pool PHP-FPM <pool> saturé (pm.max_children atteint) — Des requêtes attendent un processus libre sur <instance>. |
| `PHPFPMFileAttente` | 🟠 avertissement | 5m | <valeur> requêtes en file d'attente sur le pool <pool> — Le pool ne suit pas la charge. |
| `PHPFPMRequetesLentes` | 🟠 avertissement | immédiat | Requêtes PHP lentes sur le pool <pool> — <valeur> requêtes lentes en 5 min (voir slowlog). |

<a id="haproxy"></a>
## HAProxy — `haproxy`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `HAProxyBackendSansServeur` | 🔴 critique | 1m | Backend HAProxy <proxy> sans aucun serveur actif — Le service est indisponible pour les utilisateurs (<instance>). |
| `HAProxyServeurDown` | 🟠 avertissement | 2m | Serveur <server> DOWN dans le backend <proxy> — Health check en échec. |
| `HAProxyErreurs5xx` | 🟠 avertissement | 5m | <valeur> % d'erreurs 5xx sur le backend <proxy> — Seuil 5 % dépassé. |
| `HAProxySessionsSaturees` | 🟠 avertissement | 5m | Frontend <proxy> à <valeur> % de sa limite de sessions — Augmenter maxconn. |

<a id="rabbitmq"></a>
## RabbitMQ — `rabbitmq`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `RabbitMQAlarmeMemoire` | 🔴 critique | immédiat | RabbitMQ : alarme mémoire sur <instance> — Les éditeurs (publishers) sont bloqués tant que l'alarme est active. |
| `RabbitMQAlarmeDisque` | 🔴 critique | immédiat | RabbitMQ : alarme espace disque sur <instance> — Les éditeurs sont bloqués : libérer de l'espace disque. |
| `RabbitMQMessagesEnAttente` | 🟠 avertissement | 15m | <valeur> messages en attente sur <instance> — Les consommateurs ne suivent pas (seuil 10000). |
| `RabbitMQMessagesNonAcquittes` | 🟠 avertissement | 15m | <valeur> messages non acquittés sur <instance> — Consommateurs bloqués ou trop lents. |
| `RabbitMQSansConsommateur` | 🟠 avertissement | 10m | Aucun consommateur connecté à RabbitMQ sur <instance> — Des messages s'accumulent sans être traités. |
| `RabbitMQDescripteursFichiers` | 🟠 avertissement | 5m | RabbitMQ utilise <valeur> des descripteurs de fichiers — Augmenter LimitNOFILE. |

<a id="kafka"></a>
## Kafka — `kafka`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `KafkaBrokerPerdu` | 🔴 critique | 2m | Le cluster Kafka a perdu un broker — Il reste <valeur> brokers (<instance>). |
| `KafkaPartitionSansLeader` | 🔴 critique | 1m | Partition <partition> du topic <topic> sans leader — La partition est indisponible en lecture et écriture. |
| `KafkaPartitionsSousRepliquees` | 🟠 avertissement | 5m | <valeur> partitions sous-répliquées sur le topic <topic> — Perte de redondance : un broker est lent ou absent. |
| `KafkaRetardConsommateur` | 🟠 avertissement | 10m | Groupe <consumergroup> en retard de <valeur> messages sur <topic> — Les consommateurs ne suivent pas (seuil 1000). |

<a id="jvm"></a>
## Java / JVM et Spring Boot — `jvm`, `springboot`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `JVMHeapSaturee` | 🟠 avertissement | 10m | Heap Java à <valeur> % sur <instance> — Risque d'OutOfMemoryError : fuite mémoire ou -Xmx insuffisant. |
| `JVMTempsGCEleve` | 🟠 avertissement | 10m | La JVM passe <valeur> % de son temps en GC sur <instance> — L'application est ralentie par le ramasse-miettes (seuil 20 %). |
| `JVMThreadsNombreux` | 🟠 avertissement | 10m | <valeur> threads Java sur <instance> — Fuite de threads probable (seuil 1000). |
| `JVMInterblocageThreads` | 🔴 critique | 1m | Interblocage de threads Java sur <instance> — <valeur> threads bloqués mutuellement : faire un thread dump (jstack). |
| `ApplicationErreursHTTP5xx` | 🔴 critique | 5m | <valeur> % d'erreurs HTTP 5xx sur <instance> — Seuil 5 % dépassé (Spring Boot). |
| `ApplicationLatenceHTTP` | 🟠 avertissement | 10m | Temps de réponse moyen de <valeur> s sur <instance> — Seuil 2 s dépassé. |
| `ApplicationPoolConnexionsBDSature` | 🟠 avertissement | 5m | Pool de connexions base de données saturé (<pool>) sur <instance> — Des requêtes attendent une connexion HikariCP. |

<a id="process"></a>
## Processus — `process`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `ProcessusAbsent` | 🔴 critique | 1m | Processus <groupname> absent sur <instance> — Plus aucune instance du processus ne tourne. |
| `ProcessusDisparuDesMetriques` | 🔴 critique | immédiat | Processus <groupname> disparu des métriques sur <instance> — Le processus n'est plus détecté depuis le redémarrage de l'agent : il est probablement arrêté. |
| `ProcessusRedemarre` | 🔵 info | immédiat | Processus <groupname> redémarré sur <instance> — Redémarrage détecté dans les 10 dernières minutes. |
| `ProcessusMemoireElevee` | 🟠 avertissement | 15m | <groupname> utilise <valeur> Go de mémoire — Seuil 4 Go dépassé sur <instance>. |
| `ProcessusDescripteursFichiers` | 🟠 avertissement | 10m | <groupname> utilise <valeur> de ses descripteurs de fichiers — Risque d'erreurs 'Too many open files'. |

<a id="docker"></a>
## Conteneurs Docker (cAdvisor) — `docker`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `ConteneurDisparu` | 🟠 avertissement | immédiat | Le conteneur <name> a disparu de <instance> — Arrêté ou supprimé depuis plus de 2 minutes. |
| `ConteneurMemoireLimite` | 🟠 avertissement | 5m | Conteneur <name> à <valeur> % de sa limite mémoire — Il sera tué (OOM) s'il atteint sa limite. |
| `ConteneurTueOOM` | 🟠 avertissement | immédiat | Conteneur <name> tué par manque de mémoire — Sur <instance>. |
| `ConteneurCPUSature` | 🟠 avertissement | 15m | Conteneur <name> bridé en CPU — La limite CPU du conteneur est trop basse. |

<a id="application"></a>
## Applications instrumentées — `application`

| Alerte | Gravité | Délai | Ce qui la déclenche |
|---|---|---|---|
| `ApplicationErreurs5xx` | 🔴 critique | 5m | <valeur> % d'erreurs 5xx sur <instance> — Application instrumentée (métrique http_requests_total). |
| `ApplicationRedemarre` | 🔵 info | immédiat | <job> a redémarré sur <instance> — Démarrée il y a moins de 5 minutes. |
| `ApplicationDescripteursFichiers` | 🟠 avertissement | 10m | <job> utilise <valeur> de ses descripteurs de fichiers — Sur <instance>. |
