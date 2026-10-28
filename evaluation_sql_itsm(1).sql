/* =====================================================================
   DU Sorbonne Data Analytics — Évaluation SQL
   Sujet : Pilotage de la gestion des incidents IT (ITSM / ServiceNow)
   SGBDR : SQLite (DB Browser for SQLite)

   Source : « Incident management process enriched event log »
            Amaral, C., Fantinato, M. & Peres, S. — UCI Machine Learning
            Repository, jeu n°498, DOI 10.24432/C57S4H, licence CC BY 4.0.
            Journal d'audit réel d'une instance ServiceNow utilisée par une
            entreprise IT, anonymisé. 141 712 événements, 24 918 incidents,
            36 colonnes, février 2016 → février 2017.

   Plan du script
     1. Accès aux données (import du CSV)
     2. Exploration de la table brute (structure, valeurs manquantes, anomalies)
     3. Préparation : modèle de données propre (rôle « data engineer »)
     4. Contrôles de cohérence
     5. Exploitation : KPI et faits saillants
     6. Vues de pilotage prêtes pour un tableau de bord (Power BI / Grafana)

   Exécution : dans DB Browser, sélectionner une requête puis Ctrl+Entrée.
   Le script complet peut aussi être exécuté d'un bloc (F5) : il est rejouable.
   ===================================================================== */


/* =====================================================================
   1. ACCÈS AUX DONNÉES
   ---------------------------------------------------------------------
   Le ZIP téléchargé sur le site de l'UCI contient un seul CSV :
   incident_event_log.csv (44 Mo). Dans DB Browser for SQLite :
     Fichier > Nouvelle base de données > itsm.db
     Fichier > Importer > Table depuis un fichier CSV
       - nom de la table : raw_incident_log
       - cocher « Nom des colonnes en première ligne »
       - séparateur : virgule
   Toutes les colonnes arrivent en TEXT : on typera proprement à l'étape 3.
   La table brute n'est JAMAIS modifiée : c'est notre copie de référence.
   ===================================================================== */

-- Q1.0 Vérifier la version de SQLite (FULL JOIN et RIGHT JOIN exigent 3.39 ou plus)
SELECT sqlite_version() AS version_sqlite ;

-- Q1.1 Vérifier que l'import est complet (attendu : 141 712 lignes, 24 918 incidents)
SELECT
    COUNT(*)               AS nb_lignes,
    COUNT(DISTINCT number) AS nb_incidents
FROM raw_incident_log ;


/* =====================================================================
   2. EXPLORATION DE LA TABLE BRUTE
   ===================================================================== */

-- Q2.1 À quoi ressemble une ligne ? Le cycle de vie d'un incident, événement par événement
SELECT
    number,
    sys_mod_count,
    incident_state,
    sys_updated_at,
    assignment_group,
    priority,
    made_sla
FROM raw_incident_log
WHERE number = 'INC0000045'
ORDER BY CAST(sys_mod_count AS INTEGER) ;
-- => 1 ligne = 1 mise à jour du ticket. Ce n'est PAS une table « 1 ligne = 1 incident ».

-- Q2.2 Les états du cycle de vie et leur fréquence
SELECT
    incident_state,
    COUNT(*)                                                          AS nb_evenements,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM raw_incident_log), 1) AS pct
FROM raw_incident_log
GROUP BY incident_state
ORDER BY nb_evenements DESC ;
-- => un état « -100 » n'existe pas dans ServiceNow : anomalie à traiter.

-- Q2.3 Les 4 états « en attente » (LIKE) : combien d'incidents ont été bloqués ?
SELECT
    incident_state,
    COUNT(DISTINCT number) AS nb_incidents
FROM raw_incident_log
WHERE incident_state LIKE 'Awaiting%'
GROUP BY incident_state
ORDER BY nb_incidents DESC ;

-- Q2.4 Les valeurs manquantes ne sont pas des NULL mais des « ? »
SELECT
    SUM(CASE WHEN assignment_group = '?' THEN 1 ELSE 0 END)   AS groupe_manquant,
    SUM(CASE WHEN assigned_to      = '?' THEN 1 ELSE 0 END)   AS technicien_manquant,
    SUM(CASE WHEN category         = '?' THEN 1 ELSE 0 END)   AS categorie_manquante,
    SUM(CASE WHEN resolved_at      = '?' THEN 1 ELSE 0 END)   AS date_resolution_manquante,
    SUM(CASE WHEN closed_code      = '?' THEN 1 ELSE 0 END)   AS code_cloture_manquant,
    SUM(CASE WHEN cmdb_ci          = '?' THEN 1 ELSE 0 END)   AS equipement_cmdb_manquant,
    SUM(CASE WHEN assignment_group IS NULL THEN 1 ELSE 0 END) AS groupe_null
FROM raw_incident_log ;
-- => « IS NULL » ne trouve rien : il faudra convertir les « ? » en vrais NULL (NULLIF).
-- => cmdb_ci (l'équipement concerné) est vide à 99,7 % : inexploitable.

-- Q2.5 La règle de priorité ITIL (DISTINCT) : impact x urgence => priorité
SELECT DISTINCT
    impact,
    urgency,
    priority
FROM raw_incident_log
ORDER BY impact, urgency ;
-- => chaque couple impact / urgence donne toujours la même priorité : règle à contrôler.

-- Q2.6 Qualité des chaînes de caractères (LENGTH, SUBSTR, UPPER, REPLACE, TRIM)
SELECT
    SUM(CASE WHEN LENGTH(number) <> 10 OR UPPER(SUBSTR(number, 1, 3)) <> 'INC'
             THEN 1 ELSE 0 END)                                  AS numeros_mal_formes,
    SUM(CASE WHEN opened_by LIKE '%  %' THEN 1 ELSE 0 END)       AS double_espace_opened_by,
    MIN(CASE WHEN opened_by <> '?' THEN opened_by END)           AS exemple_brut,
    LENGTH(MIN(CASE WHEN opened_by <> '?' THEN opened_by END))   AS longueur_brute,
    MIN(CASE WHEN opened_by <> '?' THEN TRIM(REPLACE(opened_by, '  ', ' ')) END) AS exemple_nettoye
FROM raw_incident_log ;
-- => les numéros d'incident sont tous bien formés (INC + 7 chiffres),
--    mais « Opened by  8 » contient un double espace : on le corrigera avec REPLACE.

-- Q2.7 Canaux d'ouverture des tickets (au niveau incident)
SELECT
    LOWER(contact_type)    AS canal,          -- harmonisation de la casse pour l'affichage
    COUNT(DISTINCT number) AS nb_incidents
FROM raw_incident_log
GROUP BY LOWER(contact_type)
ORDER BY nb_incidents DESC ;

-- Q2.8 Le piège des dates : format J/M/AAAA H:MM, sans zéro devant
SELECT
    MIN(opened_at) AS min_texte,
    MAX(opened_at) AS max_texte
FROM raw_incident_log ;
-- => MIN = '1/1/2017' et MAX = '9/8/2016' : le tri est alphabétique, pas chronologique.
--    Les dates doivent être converties au format ISO (AAAA-MM-JJ HH:MM) avant tout calcul.

-- Q2.9 Doublons : un même numéro de mise à jour apparaît deux fois pour un incident
SELECT
    number,
    sys_mod_count,
    COUNT(*) AS nb_lignes
FROM raw_incident_log
GROUP BY number, sys_mod_count
HAVING COUNT(*) > 1 ;


/* =====================================================================
   3. PRÉPARATION DES DONNÉES (rôle « data engineer »)
   ---------------------------------------------------------------------
   Objectif : passer d'un journal brut à un petit modèle relationnel
     - ref_date              : table de conversion des dates texte -> ISO
     - ref_etat              : référentiel des états (famille, ordre)
     - incident_evenement    : 1 ligne = 1 mise à jour, typée et nettoyée
     - evenement_quarantaine : lignes écartées car invalides (traçabilité)
     - incident              : 1 ligne = 1 incident (photo au moment de la clôture)
   ===================================================================== */

-- 3.0 Script rejouable : on supprime d'abord les tables « filles », puis les « mères »
DROP TABLE IF EXISTS incident ;
DROP TABLE IF EXISTS evenement_quarantaine ;
DROP TABLE IF EXISTS incident_evenement ;
DROP TABLE IF EXISTS ref_etat ;
DROP TABLE IF EXISTS ref_date ;


-- 3.1 Table de conversion des dates
-- On rassemble toutes les dates distinctes des 4 colonnes utiles (UNION dédoublonne),
-- puis on découpe chaque texte avec INSTR / SUBSTR, couche par couche (sous-requêtes).
CREATE TABLE IF NOT EXISTS ref_date (
    date_texte TEXT PRIMARY KEY,
    date_iso   TEXT NOT NULL
) ;

INSERT INTO ref_date (date_texte, date_iso)
SELECT
    date_texte,
    -- printf('%02d') ajoute le zéro manquant : 1/3/2016 9:05 -> 2016-03-01 09:05
    printf('%s-%02d-%02d %02d:%s', annee, mois, jour, heure, minute) AS date_iso
FROM (
    -- couche 3 : dernière découpe (année / heure / minute)
    SELECT
        date_texte,
        jour,
        mois,
        SUBSTR(reste2, 1, 4)                                       AS annee,
        CAST(SUBSTR(reste2, 6, INSTR(reste2, ':') - 6) AS INTEGER) AS heure,
        SUBSTR(reste2, INSTR(reste2, ':') + 1)                     AS minute
    FROM (
        -- couche 2 : le mois, et ce qui reste après le 2e « / »
        SELECT
            date_texte,
            jour,
            CAST(SUBSTR(reste1, 1, INSTR(reste1, '/') - 1) AS INTEGER) AS mois,
            SUBSTR(reste1, INSTR(reste1, '/') + 1)                     AS reste2
        FROM (
            -- couche 1 : le jour, et ce qui reste après le 1er « / »
            SELECT
                date_texte,
                CAST(SUBSTR(date_texte, 1, INSTR(date_texte, '/') - 1) AS INTEGER) AS jour,
                SUBSTR(date_texte, INSTR(date_texte, '/') + 1)                     AS reste1
            FROM (
                SELECT opened_at      AS date_texte FROM raw_incident_log
                UNION
                SELECT resolved_at    FROM raw_incident_log
                UNION
                SELECT closed_at      FROM raw_incident_log
                UNION
                SELECT sys_updated_at FROM raw_incident_log
            )
            WHERE date_texte <> '?'
        )
    )
) ;

-- Q3.1 Contrôle de la conversion
SELECT *
FROM ref_date
WHERE date_texte IN ('29/2/2016 01:16', '1/1/2017 1:14', '9/8/2016 16:48') ;


-- 3.2 Référentiel des états (créé et alimenté à la main : CREATE TABLE + INSERT INTO ... VALUES)
-- On y met aussi « Canceled », un état standard de ServiceNow, pour vérifier s'il est utilisé.
CREATE TABLE IF NOT EXISTS ref_etat (
    etat        TEXT PRIMARY KEY,
    libelle_fr  TEXT NOT NULL,
    famille     TEXT NOT NULL,
    ordre       INTEGER
) ;

INSERT INTO ref_etat (etat, libelle_fr, famille, ordre)
VALUES
    ('New',                'Nouveau',                'Ouvert',     1),
    ('Active',             'En cours de traitement', 'Ouvert',     2),
    ('Awaiting User Info', 'En attente utilisateur', 'En attente', 3),
    ('Awaiting Evidence',  'En attente de preuve',   'En attente', 3),
    ('Awaiting Problem',   'En attente problème',    'En attente', 3),
    ('Awaiting Vendor',    'En attente fournisseur', 'En attente', 3),
    ('Resolved',           'Résolu',                 'Résolu',     4),
    ('Closed',             'Clos',                   'Clos',       5),
    ('Canceled',           'Annulé',                 'Clos',       6),
    ('-100',               'État invalide',          'Anomalie',   NULL) ;


-- 3.3 Table des événements, typée et nettoyée (INSERT INTO ... SELECT)
CREATE TABLE IF NOT EXISTS incident_evenement (
    evenement_id       INTEGER PRIMARY KEY,   -- clé technique (le couple incident/num_maj n'est pas unique, cf. Q2.9)
    incident_id        TEXT    NOT NULL,
    num_maj            INTEGER NOT NULL,
    etat               TEXT    NOT NULL,
    date_maj           TEXT,
    groupe_affectation TEXT,
    technicien         TEXT,
    priorite_code      INTEGER,
    sla_respecte       INTEGER,
    FOREIGN KEY (etat) REFERENCES ref_etat (etat)
) ;

INSERT INTO incident_evenement
    (incident_id, num_maj, etat, date_maj, groupe_affectation, technicien, priorite_code, sla_respecte)
SELECT
    r.number,
    CAST(r.sys_mod_count AS INTEGER),
    r.incident_state,
    d.date_iso,
    NULLIF(r.assignment_group, '?'),             -- « ? » devient un vrai NULL
    NULLIF(r.assigned_to, '?'),
    CAST(SUBSTR(r.priority, 1, 1) AS INTEGER),   -- '3 - Moderate' -> 3
    CASE WHEN UPPER(TRIM(r.made_sla)) = 'TRUE' THEN 1 ELSE 0 END
FROM raw_incident_log r
LEFT JOIN ref_date d ON r.sys_updated_at = d.date_texte
ORDER BY r.number, CAST(r.sys_mod_count AS INTEGER) ;


-- 3.4 Mise en quarantaine des événements invalides (CREATE TABLE ... AS SELECT, puis DELETE)
-- Bonne pratique : on copie avant de supprimer, pour garder une trace de ce qui a été écarté.
CREATE TABLE evenement_quarantaine AS
SELECT *
FROM incident_evenement
WHERE etat = '-100' ;

DELETE FROM incident_evenement
WHERE etat = '-100' ;

-- Un index (LDD, cf. typologie des commandes) accélère les recherches par incident :
-- sans lui, le contrôle C9 (sous-requête corrélée) prendrait plusieurs minutes.
CREATE INDEX IF NOT EXISTS idx_evenement_incident
    ON incident_evenement (incident_id, num_maj) ;

-- Q3.2 Contrôle : 5 lignes en quarantaine, plus aucune dans la table de travail
SELECT
    (SELECT COUNT(*) FROM evenement_quarantaine)                    AS nb_en_quarantaine,
    (SELECT COUNT(*) FROM incident_evenement WHERE etat = '-100')   AS nb_restants ;


-- 3.5 Table des incidents : 1 ligne par incident, photo prise au dernier événement « Closed »
CREATE TABLE IF NOT EXISTS incident (
    incident_id         TEXT PRIMARY KEY,
    date_ouverture      TEXT,
    date_resolution     TEXT,
    date_cloture        TEXT,
    mois_ouverture      TEXT,
    canal               TEXT,
    ouvert_par          TEXT,
    localisation        TEXT,
    categorie           TEXT,
    sous_categorie      TEXT,
    impact              INTEGER,
    urgence             INTEGER,
    priorite_code       INTEGER,
    priorite            TEXT,
    groupe_affectation  TEXT,
    technicien          TEXT,
    nb_reaffectations   INTEGER,
    nb_reouvertures     INTEGER,
    nb_mises_a_jour     INTEGER,
    sla_respecte        INTEGER,
    base_connaissance   INTEGER,
    code_cloture        TEXT,
    delai_resolution_h  REAL,
    alerte_qualite      TEXT        -- renseignée plus bas avec UPDATE
) ;

INSERT INTO incident
SELECT
    r.number,
    o.date_iso,
    rs.date_iso,
    c.date_iso,
    SUBSTR(o.date_iso, 1, 7),                               -- '2016-03'
    r.contact_type,
    NULLIF(TRIM(REPLACE(r.opened_by, '  ', ' ')), '?'),     -- corrige le double espace
    NULLIF(r.location, '?'),
    NULLIF(r.category, '?'),
    NULLIF(r.subcategory, '?'),
    CAST(SUBSTR(r.impact, 1, 1) AS INTEGER),
    CAST(SUBSTR(r.urgency, 1, 1) AS INTEGER),
    CAST(SUBSTR(r.priority, 1, 1) AS INTEGER),
    'P' || SUBSTR(r.priority, 1, 1) || ' - ' || SUBSTR(r.priority, 5),   -- '3 - Moderate' -> 'P3 - Moderate'
    NULLIF(r.assignment_group, '?'),
    NULLIF(r.assigned_to, '?'),
    CAST(r.reassignment_count AS INTEGER),
    CAST(r.reopen_count AS INTEGER),
    CAST(r.sys_mod_count AS INTEGER),
    CASE WHEN UPPER(TRIM(r.made_sla))  = 'TRUE' THEN 1 ELSE 0 END,
    CASE WHEN UPPER(TRIM(r.knowledge)) = 'TRUE' THEN 1 ELSE 0 END,
    NULLIF(r.closed_code, '?'),
    -- julianday() renvoie un nombre de jours : l'écart x 24 donne des heures
    ROUND((julianday(rs.date_iso) - julianday(o.date_iso)) * 24, 1),
    NULL
FROM raw_incident_log r
INNER JOIN (
    -- dernier événement « Closed » de chaque incident
    SELECT
        number,
        MAX(CAST(sys_mod_count AS INTEGER)) AS num_maj_max
    FROM raw_incident_log
    WHERE incident_state = 'Closed'
    GROUP BY number
) dernier ON r.number = dernier.number
         AND CAST(r.sys_mod_count AS INTEGER) = dernier.num_maj_max
         AND r.incident_state = 'Closed'
LEFT JOIN ref_date o  ON r.opened_at   = o.date_texte
LEFT JOIN ref_date rs ON r.resolved_at = rs.date_texte
LEFT JOIN ref_date c  ON r.closed_at   = c.date_texte ;


-- 3.6 Signaler les incidents à fiabiliser (UPDATE ... WHERE)
UPDATE incident
SET alerte_qualite = 'Clos sans date de résolution'
WHERE date_resolution IS NULL ;

UPDATE incident
SET alerte_qualite = 'Sans groupe d''affectation'
WHERE groupe_affectation IS NULL
  AND alerte_qualite IS NULL ;

-- Q3.3 Contrôle : 1 ligne par incident, la période couverte, les alertes posées
SELECT
    COUNT(*)                AS nb_incidents,
    MIN(date_ouverture)     AS premiere_ouverture,
    MAX(date_ouverture)     AS derniere_ouverture,
    COUNT(alerte_qualite)   AS nb_incidents_en_alerte
FROM incident ;


/* =====================================================================
   4. CONTRÔLES DE COHÉRENCE
   ===================================================================== */

-- Q4.1 Référentiel vs réalité (FULL JOIN) : états prévus jamais utilisés / états inconnus
-- (Si votre version de SQLite refuse FULL JOIN, remplacer par LEFT JOIN : même lecture côté référentiel.)
SELECT
    r.etat        AS etat_du_referentiel,
    o.etat        AS etat_observe,
    o.nb_evenements
FROM ref_etat r
FULL JOIN (
    SELECT incident_state AS etat, COUNT(*) AS nb_evenements
    FROM raw_incident_log
    GROUP BY incident_state
) o ON r.etat = o.etat
WHERE r.etat IS NULL
   OR o.etat IS NULL ;
-- => « Canceled » est prévu mais jamais utilisé : aucun incident n'a été annulé.

-- Q4.2 Les groupes « de transit » (RIGHT JOIN) : ils reçoivent des tickets mais n'en clôturent aucun
SELECT
    g.groupe_affectation,
    COUNT(i.incident_id) AS nb_incidents_clos_par_le_groupe
FROM incident i
RIGHT JOIN (
    SELECT DISTINCT groupe_affectation
    FROM incident_evenement
    WHERE groupe_affectation IS NOT NULL
) g ON i.groupe_affectation = g.groupe_affectation
GROUP BY g.groupe_affectation
HAVING COUNT(i.incident_id) = 0 ;


-- 4.3 Vue des contrôles : des règles de qualité rejouables à chaque mise à jour des données.
-- Chaque ligne = une règle, son nombre d'anomalies et son taux.
-- (UNION ALL empile les résultats de plusieurs SELECT ayant les mêmes colonnes.)
DROP VIEW IF EXISTS v_controles_coherence ;

CREATE VIEW IF NOT EXISTS v_controles_coherence AS
SELECT
    controle,
    nb_anomalies,
    ROUND(nb_anomalies * 100.0 / (SELECT COUNT(*) FROM incident), 2) AS pct_incidents
FROM (
    SELECT 'C1 - Mise à jour en double (incident / n° de maj)' AS controle,
           (SELECT COUNT(*) FROM (SELECT number FROM raw_incident_log
                                  GROUP BY number, sys_mod_count HAVING COUNT(*) > 1)) AS nb_anomalies
    UNION ALL
    SELECT 'C2 - Incident passé par un état invalide (-100)',
           COUNT(DISTINCT incident_id) FROM evenement_quarantaine
    UNION ALL
    SELECT 'C3 - Priorité incohérente avec la matrice impact x urgence',
           COUNT(*) FROM incident
           WHERE priorite_code <> CASE
                                     WHEN impact + urgence = 2 THEN 1
                                     WHEN impact + urgence = 3 THEN 2
                                     WHEN impact + urgence = 4 THEN 3
                                     ELSE 4
                                  END
    UNION ALL
    SELECT 'C4 - Incident clos sans date de résolution',
           COUNT(*) FROM incident WHERE date_resolution IS NULL
    UNION ALL
    SELECT 'C5 - Résolution antérieure à l''ouverture',
           COUNT(*) FROM incident WHERE date_resolution < date_ouverture
    UNION ALL
    SELECT 'C6 - Clôture antérieure à la résolution',
           COUNT(*) FROM incident WHERE date_cloture < date_resolution
    UNION ALL
    SELECT 'C7 - Incident clos sans code de clôture',
           COUNT(*) FROM incident WHERE code_cloture IS NULL
    UNION ALL
    SELECT 'C8 - Incident sans groupe d''affectation',
           COUNT(*) FROM incident WHERE groupe_affectation IS NULL
    UNION ALL
    -- EXISTS : existe-t-il, pour cet incident, un événement non « Closed » après sa 1re clôture ?
    SELECT 'C9 - Activité après la clôture (ticket rouvert après Closed)',
           COUNT(*) FROM incident i
           WHERE EXISTS (
               SELECT 1
               FROM incident_evenement e
               WHERE e.incident_id = i.incident_id
                 AND e.etat <> 'Closed'
                 AND e.num_maj > (SELECT MIN(num_maj)
                                  FROM incident_evenement c
                                  WHERE c.incident_id = i.incident_id
                                    AND c.etat = 'Closed')
           )
) ;

-- Q4.3 Tableau des contrôles
SELECT *
FROM v_controles_coherence ;


/* =====================================================================
   5. EXPLOITATION : KPI ET FAITS SAILLANTS
   ===================================================================== */

-- Q5.1 Vue d'ensemble (les KPI « en-tête » d'un tableau de bord)
SELECT
    COUNT(*)                                       AS nb_incidents,
    ROUND(AVG(sla_respecte) * 100, 1)              AS pct_sla_respecte,
    ROUND(AVG(delai_resolution_h), 1)              AS delai_moyen_resolution_h,
    MAX(delai_resolution_h)                        AS delai_max_h,
    ROUND(AVG(nb_reaffectations), 2)               AS reaffectations_moyennes,
    ROUND(AVG(CASE WHEN nb_reouvertures > 0 THEN 1.0 ELSE 0 END) * 100, 1) AS pct_reouverts,
    ROUND(AVG(base_connaissance) * 100, 1)         AS pct_base_connaissance
FROM incident ;

-- Q5.2 Moyenne trompeuse : la médiane du délai de résolution (sous-requête + LIMIT / OFFSET)
SELECT delai_resolution_h AS delai_median_h
FROM incident
WHERE delai_resolution_h IS NOT NULL
ORDER BY delai_resolution_h
LIMIT 1
OFFSET (SELECT COUNT(*) / 2 FROM incident WHERE delai_resolution_h IS NOT NULL) ;

-- Q5.3 Distribution des délais par tranche (CASE WHEN)
SELECT
    CASE
        WHEN delai_resolution_h IS NULL THEN '0. non résolu / date absente'
        WHEN delai_resolution_h < 4     THEN '1. moins de 4 h'
        WHEN delai_resolution_h < 24    THEN '2. 4 h à 1 jour'
        WHEN delai_resolution_h < 72    THEN '3. 1 à 3 jours'
        WHEN delai_resolution_h < 168   THEN '4. 3 à 7 jours'
        WHEN delai_resolution_h < 720   THEN '5. 7 à 30 jours'
        ELSE                                 '6. plus de 30 jours'
    END                                               AS tranche_delai,
    COUNT(*)                                          AS nb_incidents,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM incident), 1) AS pct,
    ROUND(AVG(sla_respecte) * 100, 1)                 AS pct_sla_respecte
FROM incident
GROUP BY tranche_delai
ORDER BY tranche_delai ;

-- Q5.4 SLA et délai par priorité : là où ça fait mal
SELECT
    priorite,
    COUNT(*)                            AS nb_incidents,
    ROUND(AVG(delai_resolution_h), 1)   AS delai_moyen_h,
    ROUND(AVG(sla_respecte) * 100, 1)   AS pct_sla_respecte,
    ROUND(AVG(nb_reaffectations), 2)    AS reaffectations_moyennes
FROM incident
GROUP BY priorite
ORDER BY priorite ;

-- Q5.5 Évolution mensuelle (volume et qualité de service)
SELECT
    mois_ouverture,
    COUNT(*)                            AS nb_incidents,
    ROUND(AVG(sla_respecte) * 100, 1)   AS pct_sla_respecte,
    ROUND(AVG(delai_resolution_h), 1)   AS delai_moyen_h,
    CASE WHEN COUNT(*) < 1000 THEN 'mois partiel / résiduel' ELSE 'mois complet' END AS statut_mois
FROM incident
GROUP BY mois_ouverture
ORDER BY mois_ouverture ;

-- Q5.6 Grille mois x priorité sur la période de référence (CROSS JOIN + LEFT JOIN + BETWEEN)
-- Le CROSS JOIN crée toutes les combinaisons, même vides : indispensable pour un graphique sans « trous ».
SELECT
    m.mois_ouverture,
    p.priorite,
    COUNT(i.incident_id)                    AS nb_incidents,
    ROUND(AVG(i.sla_respecte) * 100, 1)     AS pct_sla_respecte
FROM (
    SELECT DISTINCT mois_ouverture
    FROM incident
    WHERE date_ouverture BETWEEN '2016-03-01' AND '2016-05-31 23:59'
) m
CROSS JOIN (SELECT DISTINCT priorite FROM incident) p
LEFT JOIN incident i ON i.mois_ouverture = m.mois_ouverture
                    AND i.priorite       = p.priorite
GROUP BY m.mois_ouverture, p.priorite
ORDER BY m.mois_ouverture, p.priorite ;

-- Q5.7 Pilotage par équipe : les groupes les plus sollicités (HAVING = au moins 300 incidents)
SELECT
    groupe_affectation,
    COUNT(*)                            AS nb_incidents,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM incident), 1) AS part_volume_pct,
    ROUND(AVG(sla_respecte) * 100, 1)   AS pct_sla_respecte,
    ROUND(AVG(delai_resolution_h), 1)   AS delai_moyen_h,
    ROUND(AVG(nb_reaffectations), 2)    AS reaffectations_moyennes
FROM incident
WHERE groupe_affectation IS NOT NULL
GROUP BY groupe_affectation
HAVING COUNT(*) >= 300
ORDER BY nb_incidents DESC ;

-- Q5.8 Le coût des réaffectations (« ping-pong » entre équipes)
SELECT
    CASE
        WHEN nb_reaffectations = 0 THEN '0 - traité par la 1re équipe'
        WHEN nb_reaffectations = 1 THEN '1 réaffectation'
        WHEN nb_reaffectations = 2 THEN '2 réaffectations'
        ELSE                            '3 réaffectations ou plus'
    END                                 AS niveau_reaffectation,
    COUNT(*)                            AS nb_incidents,
    ROUND(AVG(delai_resolution_h), 1)   AS delai_moyen_h,
    ROUND(AVG(sla_respecte) * 100, 1)   AS pct_sla_respecte
FROM incident
GROUP BY niveau_reaffectation
ORDER BY niveau_reaffectation ;

-- Q5.9 Effet de l'attente utilisateur (sous-requête IN sur la table des événements)
SELECT
    CASE WHEN i.incident_id IN (SELECT incident_id
                                FROM incident_evenement
                                WHERE etat = 'Awaiting User Info')
         THEN 'Passé par « en attente utilisateur »'
         ELSE 'Jamais en attente utilisateur' END AS parcours,
    COUNT(*)                                       AS nb_incidents,
    ROUND(AVG(i.delai_resolution_h), 1)            AS delai_moyen_h,
    ROUND(AVG(i.sla_respecte) * 100, 1)            AS pct_sla_respecte
FROM incident i
GROUP BY parcours ;

-- Q5.10 La base de connaissances accélère-t-elle la résolution ?
SELECT
    CASE WHEN base_connaissance = 1 THEN 'Article de connaissance utilisé'
         ELSE 'Pas d''article' END      AS usage_kb,
    COUNT(*)                            AS nb_incidents,
    ROUND(AVG(delai_resolution_h), 1)   AS delai_moyen_h,
    ROUND(AVG(sla_respecte) * 100, 1)   AS pct_sla_respecte,
    ROUND(AVG(nb_reaffectations), 2)    AS reaffectations_moyennes
FROM incident
GROUP BY usage_kb ;
-- => attention : corrélation n'est pas causalité (on consulte un article surtout sur les cas difficiles).

-- Q5.11 Pareto des catégories : combien de catégories font l'essentiel du volume ?
SELECT
    categorie,
    COUNT(*)                                                     AS nb_incidents,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM incident), 1) AS part_pct,
    ROUND(AVG(sla_respecte) * 100, 1)                            AS pct_sla_respecte
FROM incident
GROUP BY categorie
ORDER BY nb_incidents DESC
LIMIT 10 ;

-- Q5.12 Liste d'actions : incidents P1/P2 plus de 3 fois plus lents que la moyenne de leur priorité
SELECT
    i.incident_id,
    i.priorite,
    i.groupe_affectation,
    i.delai_resolution_h,
    ROUND(m.delai_moyen_priorite, 1) AS delai_moyen_priorite,
    i.nb_reaffectations
FROM incident i
INNER JOIN (
    SELECT priorite_code, AVG(delai_resolution_h) AS delai_moyen_priorite
    FROM incident
    GROUP BY priorite_code
) m ON i.priorite_code = m.priorite_code
WHERE i.delai_resolution_h > 3 * m.delai_moyen_priorite
  AND i.priorite_code <= 2
ORDER BY i.delai_resolution_h DESC
LIMIT 10 ;


/* =====================================================================
   6. VUES DE PILOTAGE (couche « prête à consommer » pour Power BI / Grafana)
   ===================================================================== */

-- 6.1 Suivi mensuel
DROP VIEW IF EXISTS v_kpi_mensuel ;

CREATE VIEW IF NOT EXISTS v_kpi_mensuel AS
SELECT
    mois_ouverture,
    COUNT(*)                                                         AS nb_incidents,
    SUM(CASE WHEN priorite_code <= 2 THEN 1 ELSE 0 END)              AS nb_critiques_hautes,
    ROUND(AVG(sla_respecte) * 100, 1)                                AS pct_sla_respecte,
    ROUND(AVG(delai_resolution_h), 1)                                AS delai_moyen_h,
    ROUND(AVG(CASE WHEN nb_reaffectations = 0 THEN 1.0 ELSE 0 END) * 100, 1) AS pct_resolus_1re_equipe
FROM incident
GROUP BY mois_ouverture ;

-- 6.2 Tableau de bord par équipe (avec un indicateur d'alerte)
DROP VIEW IF EXISTS v_pilotage_groupes ;

CREATE VIEW IF NOT EXISTS v_pilotage_groupes AS
SELECT
    groupe_affectation,
    COUNT(*)                                     AS nb_incidents,
    ROUND(AVG(sla_respecte) * 100, 1)            AS pct_sla_respecte,
    ROUND(AVG(delai_resolution_h), 1)            AS delai_moyen_h,
    ROUND(AVG(nb_reaffectations), 2)             AS reaffectations_moyennes,
    CASE
        WHEN AVG(sla_respecte) < 0.5 THEN 'Rouge - SLA < 50 %'
        WHEN AVG(sla_respecte) < (SELECT AVG(sla_respecte) FROM incident) THEN 'Orange - sous la moyenne'
        ELSE 'Vert'
    END                                          AS alerte
FROM incident
WHERE groupe_affectation IS NOT NULL
GROUP BY groupe_affectation ;

-- Q6.1 Utilisation : les équipes à surveiller en priorité
SELECT *
FROM v_pilotage_groupes
WHERE nb_incidents >= 100
  AND alerte <> 'Vert'
ORDER BY nb_incidents DESC
LIMIT 10 ;

-- Q6.2 Utilisation : la vue mensuelle
SELECT *
FROM v_kpi_mensuel
ORDER BY mois_ouverture ;





/* =====================================================================
   7. PASSAGE À POWER BI
   ---------------------------------------------------------------------
   Une vue au niveau le plus fin (1 ligne = 1 incident) avec les règles
   métier déjà calculées : Power BI agrège et filtre, SQL garde la logique.
   ===================================================================== */
DROP VIEW IF EXISTS v_incident_bi ;

CREATE VIEW IF NOT EXISTS v_incident_bi AS
SELECT
    i.incident_id,
    i.date_ouverture,
    i.date_resolution,
    i.mois_ouverture,
    i.canal,
    i.categorie,
    i.priorite,
    i.groupe_affectation,
    i.nb_reaffectations,
    i.sla_respecte,
    i.base_connaissance,
    i.delai_resolution_h,
    i.alerte_qualite,
    CASE
        WHEN i.nb_reaffectations = 0 THEN '0 - 1re équipe'
        WHEN i.nb_reaffectations = 1 THEN '1 réaffectation'
        WHEN i.nb_reaffectations = 2 THEN '2 réaffectations'
        ELSE '3 ou plus'
    END AS niveau_reaffectation,
    CASE
        WHEN i.delai_resolution_h IS NULL THEN '0. non renseigné'
        WHEN i.delai_resolution_h < 4     THEN '1. < 4 h'
        WHEN i.delai_resolution_h < 24    THEN '2. 4 h à 1 j'
        WHEN i.delai_resolution_h < 72    THEN '3. 1 à 3 j'
        WHEN i.delai_resolution_h < 168   THEN '4. 3 à 7 j'
        ELSE                                   '5. > 7 j'
    END AS tranche_delai,
    CASE WHEN i.incident_id IN (SELECT incident_id
                                FROM incident_evenement
                                WHERE etat = 'Awaiting User Info')
         THEN 1 ELSE 0 END AS passe_attente_utilisateur
FROM incident i ;

-- Q7.1 Contrôle : 24 918 lignes et les mêmes chiffres que la partie 5
SELECT
    COUNT(*)                                  AS nb_incidents,
    ROUND(AVG(sla_respecte) * 100, 1)         AS pct_sla_respecte,
    SUM(passe_attente_utilisateur)            AS nb_passes_attente_utilisateur
FROM v_incident_bi ;
