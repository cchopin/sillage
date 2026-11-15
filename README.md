# Sillage

**La carte des flux du Query Store.**

Démo en ligne : <https://cchopin.github.io/sillage/> (jeu de démonstration fictif, aucune donnée réelle).

Une carte interactive des flux de données d'une instance SQL Server, construite uniquement à partir du Query Store. Le principe : une extraction SQL produit un fichier JSON, la page HTML lit ce fichier et construit la carte toute seule. Rejouable sur n'importe quelle instance.

## État du projet

- **Front (`index.html`)** : vérifié sur le jeu de démonstration uniquement (contrôle de syntaxe des scripts, ouverture de la page et affichage de la carte de démonstration).
- **Extraction (`sql/extraction-query-store.sql`) et lanceur (`scripts/extraire.ps1`)** : pas encore exécutés sur une instance SQL Server réelle. Ils n'ont été que relus. Les retours d'exécution, y compris les erreurs, sont bienvenus.

## Contenu du kit

| Fichier | Rôle |
| --- | --- |
| `sql/extraction-query-store.sql` | Requêtes d'extraction, en lecture seule, qui renvoient un document JSON |
| `scripts/extraire.ps1` | Lance le script SQL et écrit le JSON dans un fichier |
| `index.html` | Le front : s'ouvre dans un navigateur, sans serveur ni installation |
| `exemples/flux-exemple.json` | Jeu de démonstration, au format attendu par le front |

## Prérequis

- SQL Server 2016 ou plus récent, Query Store activé sur les bases à cartographier.
- Droits `VIEW SERVER STATE` et `VIEW DATABASE STATE` (ou sysadmin).
- Les attentes de verrou ne sont disponibles qu'à partir de SQL Server 2017.
- Un intervalle Query Store de 60 minutes ou moins. Au-delà, la répartition par heure est approximative et le front le signale.

## Utilisation

1. Lancer l'extraction, depuis la racine du dépôt :

```powershell
.\scripts\extraire.ps1 -Serveur SRV-SQL01 -Sortie flux.json
```

Avec une authentification SQL :

```powershell
.\scripts\extraire.ps1 -Serveur SRV-SQL01 -Utilisateur lecteur_qs -Sortie flux.json
```

2. Ouvrir `index.html` dans un navigateur (ou la démo en ligne).
3. Cliquer sur « Charger un fichier JSON », ou glisser `flux.json` sur la carte.

Sans PowerShell, le script SQL s'exécute tel quel dans SSMS ou Azure Data Studio : il renvoie une seule cellule à copier dans un fichier `.json`. SSMS tronque les longues cellules, Azure Data Studio est plus fiable pour cette copie.

## Réglages de l'extraction

En tête de `sql/extraction-query-store.sql` :

| Variable | Défaut | Effet |
| --- | --- | --- |
| `@Jours` | 7 | Profondeur d'historique analysée |
| `@TopRequetes` | 60 | Requêtes détaillées par base, pour chacun des trois classements (CPU, lignes, lectures logiques). Les autres sont regroupées |
| `@TopTables` | 200 | Tables décrites par base, les plus volumineuses |
| `@TexteMax` | 300 | Longueur du texte de requête exporté, 0 pour ne rien exporter |
| `@TailleMinMo` | 0 | Ignore les bases plus petites que ce seuil |
| `@Bases` | vide | Liste de bases séparées par des virgules, vide pour toutes |

## Réglages du front

Le panneau « Réglages de la carte » permet de :

- choisir la mesure des flux : lignes, exécutions, temps CPU, durée, lectures ou écritures logiques ;
- masquer les bases sous une taille donnée ;
- décocher des bases une par une ;
- plafonner le nombre de noeuds affichés (les moins actifs sont masqués) ;
- fixer le seuil d'alerte sur les attentes de verrou ;
- masquer les requêtes qui n'ont pu être rattachées à aucune table ;
- afficher ou non les logins connectés au moment de l'extraction.

Les réglages sont mémorisés dans le navigateur. Les noeuds se déplacent à la souris. Un double-clic sur une base ouvre la vue par tables.

## Comment les flux sont déduits

- Le plan d'exécution le plus utilisé de chaque requête retenue donne la liste des tables touchées, y compris dans d'autres bases, et distingue lectures et écritures.
- Une requête en lecture seule crée un flux de chaque table lue vers « Applications ».
- Une requête d'écriture crée un flux de chaque table lue vers la table écrite. Sans table source, le flux part de « Applications ».
- Une requête stockée dans la base A qui touche une table de la base B crée un flux entre bases.
- Les volumes sont des moyennes par heure, pour chaque créneau jour de semaine et heure, en heure locale du serveur.

## Limites à connaître

- Le Query Store ne sait pas qui se connecte : les flux de requêtes aboutissent tous au noeud « Applications ». En complément, l'extraction prend une photo de `sys.dm_exec_sessions` : la vue instance affiche un noeud par login, relié en pointillé aux bases où il a des sessions ouvertes. Cette photo ne porte aucun volume et ne voit que les sessions ouvertes à l'instant de l'extraction : un traitement nocturne n'apparaît pas si l'extraction tourne en journée.
- Une requête qui lit plusieurs tables attribue son volume entier à chacune : les flux d'une même requête ne s'additionnent pas.
- Les vérifications de clés étrangères apparaissent comme des tables sources d'une écriture.
- Les tables temporaires et les objets système sont ignorés.
- Les plans trop profonds pour être convertis en XML sont rattachés au noeud « (autres) » de leur base.
- Les requêtes hors sélection sont regroupées sous « (autres) », comptées en lecture.
- Sur une base secondaire d'un groupe de disponibilité, le Query Store reflète l'activité du primaire, sauf si le Query Store pour réplicas secondaires est activé (SQL Server 2022).

## Confidentialité

Une extraction réelle ne doit jamais être commitée : le `.gitignore` exclut tous les fichiers `*.json` sauf ceux du dossier `exemples/`.

Le fichier JSON contient des noms de bases, de tables, de procédures et de logins, ainsi que des extraits de texte de requêtes qui peuvent inclure des valeurs littérales. Mettre `@TexteMax` à 0 avant de partager un fichier hors de l'équipe. La page HTML ne transmet rien : le fichier est lu localement par le navigateur.

## Format du JSON

```json
{
  "meta":     { "serveur": "", "version": "", "extrait_le": "", "jours": 7, "top_requetes": 60 },
  "bases":    [ { "db": "", "mo": 0, "data_mo": 0, "log_mo": 0, "qs_min": 60, "qs_etat": "", "debut": "", "fin": "", "erreur": "" } ],
  "tables":   [ { "db": "", "t": "schema.table", "lignes": 0, "mo": 0 } ],
  "requetes": [ { "db": "", "q": 0, "txt": "", "obj": "schema.procedure" } ],
  "objets":   [ { "db": "", "q": 0, "odb": "", "ot": "schema.table", "w": 0 } ],
  "clients":  [ { "db": "", "login": "", "prog": "", "hotes": 0, "sessions": 0, "cpu_ms": 0, "lr": 0, "ecr": 0 } ],
  "horaire":  [ { "db": "", "q": 0, "s": 0, "e": 0, "r": 0, "c": 0, "d": 0, "lr": 0, "lw": 0, "lk": 0 } ]
}
```

Dans `horaire`, `s` est le créneau (0 pour lundi 0 h, 167 pour dimanche 23 h). Les autres champs sont des cumuls sur la période : `e` exécutions, `r` lignes, `c` CPU en ms, `d` durée en ms, `lr` et `lw` lectures et écritures logiques en pages, `lk` attente de verrou en ms. `q` vaut 0 pour le regroupement des requêtes hors sélection. Dans `objets`, `w` vaut 1 pour une table écrite. `clients` est facultatif : une ligne par base et par login, avec le nombre de sessions ouvertes à l'extraction.

## Licence

MIT, voir [LICENSE](LICENSE).
