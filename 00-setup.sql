-- =============================================================================
-- Load-test weight data: setup
--
-- Creates helper functions and procedures that inflate
-- sentinel.migrated_customers and sentinel.customer with synthetic rows so the
-- trigram GIN indexes (first_name, last_name, full_name) and the birth_date
-- partitions carry realistic weight. Rows are not meant to be searched.
--
-- Birth years follow the age curve in the TUNABLES section below, not the
-- original rows' spread. p_copies is the AVERAGE number of synthetic rows per
-- original row; each birth year gets as many copies per original as its share
-- of the curve needs. Preview a load before running it:
--   SELECT * FROM sentinel.lt_plan('migrated_customers', 12127);
--   SELECT * FROM sentinel.lt_plan('customer', 12127);
--
-- Original rows are the migrated_customers rows that carry a ucms_record_hash.
-- Synthetic rows are marked, and cleanup deletes only rows carrying every
-- marker:
--   migrated_customers: raw_info ? 'lt' AND ucms_record_hash IS NULL
--                       AND legacy_ids IS NULL
--   customer:           metadata ? 'lt'
--                       AND created_at = 1999-01-01 00:00:00+00
--
-- The fixed 1999 timestamps on customer keep synthetic rows out of every
-- FinCense EOD delta window (created_at / updated_at filter) while leaving
-- them inside every deleted_at IS NULL partial index.
--
-- Run order: 00-setup.sql -> 10-run.sql -> (later) 99-cleanup.sql
-- Requirements:
--   * psql in autocommit mode (default). CALL must not run inside BEGIN,
--     because the procedures COMMIT after every chunk.
--   * Connect to the cluster writer endpoint directly, not RDS Proxy.
--   * Role needs CREATE on schema sentinel, and SELECT/INSERT/DELETE on
--     sentinel.migrated_customers and sentinel.customer.
--   * PostgreSQL 13+ (gen_random_uuid() in core, pg_attribute.attgenerated).
-- SIT / non-production only.
-- =============================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------------------
-- TUNABLES: edit here, then re-run this file.
--
-- lt_age_curve: relative weight per year of age, by age band. Only the shape
-- matters: weights are normalised across the birth years that have original
-- rows. Age is counted from the current year. An age in no band gets 0.
-- target 'both' applies to both tables; rows for 'migrated_customers' or
-- 'customer' give that table its own curve and replace the 'both' rows for it
-- entirely. Bands for one target must not overlap.
--
-- From a histogram, give each band its count divided by the number of ages in
-- it. The values below come from PGC's age-group counts over 22,730,620
-- records (ages as of 2026).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_age_curve()
RETURNS TABLE (target text, age_from int, age_to int, weight numeric)
LANGUAGE sql
IMMUTABLE
AS $$
  VALUES
    -- target       age_from  age_to   weight     group (records)
    ('both'::text,         0,     13,       19),  -- Newborn + Alpha (265)
    ('both',              14,     29,   273096),  -- Gen Z (4,369,540)
    ('both',              30,     45,   616052),  -- Millennials (9,856,830)
    ('both',              46,     61,   370691),  -- Gen X (5,931,057)
    ('both',              62,     80,   128473),  -- Boomers (2,440,990)
    ('both',              81,    100,     6595)   -- Silent and older (131,891)
$$;

-- -----------------------------------------------------------------------------
-- lt_unknown_share: fraction of each table's synthetic rows given to original
-- rows whose birth date is NULL or outside 1945-2014 (the 'outside' chunk).
-- 0 leaves those rows uncopied. 0.0055 is PGC's share of records born before
-- 1945 or after 2014, plus the invalid, future-dated and system-default ones.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_unknown_share(p_target text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_target
           WHEN 'migrated_customers' THEN 0.0055
           WHEN 'customer'           THEN 0.0055
         END
$$;

-- -----------------------------------------------------------------------------
-- Name pickers: realistic Filipino given-name and surname distributions.
--
-- Given names: ~250-name pool ordered by rough commonness, drawn with a
-- geometric skew (the most common name leads ~2% of first names); 15% are
-- blended spellings ("Jolyn", "Marrey"); 30% carry a second given name
-- ("Maria Luz", "John Paul"). Tens of thousands of distinct values.
--
-- Surnames: 30% from a ~200-name pool of common surnames with the same skew
-- (top surname ~0.6% of rows, top 100 ~25%); 70% from a syllable-built long
-- tail (~480k two- and three-syllable combinations, ~2.9M including the 4%
-- that carry a Dela/De/Del/Delos/San particle).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_first_name()
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  pool CONSTANT text[] := ARRAY[
    'Maria','Jose','Juan','Mark','John','Michael','Ana','Rosario','Angelo','Christian',
    'Joseph','Jerome','Kevin','Joshua','Daniel','Gabriel','Carlo','Paolo','Miguel','Rafael',
    'Jonathan','Jayson','Jeffrey','Marvin','Alvin','Ronaldo','Rodel','Rommel','Arnel','Edgardo',
    'Rogelio','Eduardo','Ricardo','Ramon','Antonio','Manuel','Fernando','Roberto','Danilo','Reynaldo',
    'Noel','Ernesto','Leonardo','Virgilio','Teodoro','Lorenzo','Emmanuel','Luz','Elena','Teresa',
    'Josefina','Corazon','Remedios','Lourdes','Carmelita','Evangeline','Marites','Maricel','Maricar','Mylene',
    'Rowena','Jocelyn','Lorna','Gemma','Analyn','Rachelle','Kristine','Angelica','Jasmine','Nicole',
    'Princess','Camille','Andrea','Patricia','Katherine','Grace','Joy','Rhea','Charmaine','Divina',
    'Leonora','Imelda','Milagros','Perla','Norma','Estrella','Gloria','Cecilia','Aurora','Rosalinda',
    'Marilou','Jennifer','Janine','Aileen','Bea','Mary','Jane','Anne','Rose','Paul',
    'Peter','James','Robert','William','Richard','Charles','Anthony','Vincent','Ryan','Bryan',
    'Jason','Dennis','Randy','Rey','Ramil','Joel','Jomar','Jhon','Allan','Arvin',
    'Erwin','Edwin','Melvin','Nestor','Rolando','Renato','Romeo','Alfredo','Armando','Benjamin',
    'Bernardo','Cesar','Dante','Efren','Felix','Gerardo','Gilbert','Herminio','Ignacio','Jaime',
    'Julius','Leo','Lito','Mario','Nelson','Oscar','Pedro','Quirino','Raul','Samuel',
    'Tomas','Victor','Wilfredo','Zaldy','Aida','Alma','Amelia','Angelina','Arlene','Beatriz',
    'Carmen','Cristina','Dolores','Editha','Elvira','Emily','Erlinda','Felicidad','Flordeliza','Gina',
    'Helen','Irene','Isabel','Jenny','Juliet','Karen','Leticia','Liza','Lolita','Lucia',
    'Lydia','Maribel','Marissa','Melanie','Michelle','Mila','Myrna','Nancy','Nora','Ofelia',
    'Pilar','Rebecca','Regina','Ruby','Sheila','Shirley','Sonia','Susan','Thelma','Veronica',
    'Vilma','Wilma','Yolanda','Zenaida','Althea','Bianca','Chloe','Danica','Ella','Francine',
    'Hannah','Ivy','Janelle','Kyla','Lovely','Mae','Nina','Pia','Queenie','Rica',
    'Sofia','Trisha','Venice','Ysabel','Aldrin','Bryle','Carl','Dexter','Elijah','Francis',
    'Gerald','Harold','Ivan','Jake','Kenneth','Lance','Marlon','Neil','Owen','Prince',
    'Rhon','Sean','Tristan','Wendell','Xander','Zion','Bienvenido','Rizalino','Crisanto','Jericho'
  ];
  sfx CONSTANT text[] := ARRAY[
    'lyn','line','rey','mae','jean','son','elle','ito','ita','ie','an','el','iel',
    'ette','ly','ine','ra','na','den','ric','win','zel','jie','boy','anne','ell'
  ];
  n CONSTANT int := array_length(pool, 1);
  v text;
BEGIN
  IF random() < 0.15 THEN
    v := initcap(left(lower(pool[1 + floor(random() * n)::int]), 2 + floor(random() * 3)::int)
                 || sfx[1 + floor(random() * array_length(sfx, 1))::int]);
  ELSE
    v := pool[1 + (floor(-ln(1 - random()) * 45)::int % n)];
  END IF;
  IF random() < 0.30 THEN
    v := v || ' ' || pool[1 + (floor(-ln(1 - random()) * 45)::int % n)];
  END IF;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION sentinel.lt_last_name()
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  pool CONSTANT text[] := ARRAY[
    'Dela Cruz','Garcia','Reyes','Ramos','Mendoza','Santos','Flores','Gonzales','Bautista','Villanueva',
    'Fernandez','Cruz','De Guzman','Lopez','Perez','Castillo','Francisco','Rivera','Aquino','Castro',
    'Sanchez','Torres','De Leon','Domingo','Martinez','Rodriguez','Santiago','Soriano','Delos Santos','Diaz',
    'Hernandez','Tolentino','Valdez','Ramirez','Morales','Mercado','Tan','Aguilar','Navarro','Manalo',
    'Gomez','Dizon','Del Rosario','Javier','Corpuz','Gutierrez','Salvador','Velasco','Miranda','David',
    'Salazar','Fajardo','Mariano','Pascual','Ocampo','Serrano','Marquez','Rosales','Lim','Sy',
    'Go','Chua','Ong','Yap','Magbanua','Macaraeg','Dimaculangan','Panganiban','Mangubat','Dimaano',
    'Macapagal','Manalastas','Lacson','Sison','Samonte','Evangelista','Galang','Pangilinan','Mallari','Sarmiento',
    'Gatchalian','Lacsamana','Padilla','Estrada','Enriquez','Robles','Romero','Jimenez','Alvarez','Cabrera',
    'Espinosa','Medina','Vargas','Guevarra','Ignacio','Agustin','Caballero','Abad','Belmonte','Buenaventura',
    'Concepcion','Custodio','Dela Paz','Esguerra','Ilagan','Lagman','Maglaya','Quiambao','Andrada','Tomas',
    'Alcantara','Aragon','Arellano','Avila','Baltazar','Bernardo','Blanco','Bonifacio','Buenafe','Cabral',
    'Calderon','Carreon','Catacutan','Cervantes','Cordero','Cortez','Cuevas','Dalisay','Dantes','Datu',
    'De Castro','De Jesus','Dela Rosa','Del Mundo','Dumlao','Ebarle','Encarnacion','Escobar','Espiritu','Estrella',
    'Eugenio','Fabian','Felipe','Galvez','Gamboa','Geronimo','Gregorio','Guerrero','Hidalgo','Ibarra',
    'Jacinto','Labrador','Lacanilao','Laurel','Legaspi','Leonardo','Lualhati','Luna','Mabini','Madrigal',
    'Magno','Malabanan','Maligaya','Manansala','Manuel','Marasigan','Mateo','Matias','Montemayor','Nepomuceno',
    'Nicolas','Nolasco','Pacheco','Pagdanganan','Palma','Paras','Pineda','Quijano','Quinto','Rafael',
    'Regalado','Rosario','Sabado','Salonga','Samson','Santillan','Sebastian','Silva','Tadeo','Tiongson',
    'Trinidad','Umali','Vasquez','Velasquez','Vergara','Villareal','Yambao','Zamora','Zabala','Zulueta'
  ];
  syl CONSTANT text[] := ARRAY[
    'ba','bu','bi','da','di','ga','gu','ha','hi','la','li','lu','ma','mi','mu','na','ni','pa',
    'pi','pu','sa','si','su','ta','ti','tu','ya','ca','co','ro','ri','ra','an','ang','ay','ag',
    'al','am','as','at','og','on','ong','in','ing','il','ol','os','es','ez','ino','ado','ega','era',
    'ilo','ayo','ban','dan','gan','lan','man','nan','pan','san','tan','bay','may','bal','dal','lag',
    'tag','bag','hon','quin','cion','sol','nor','rio'
  ];
  pre CONSTANT text[] := ARRAY['Dela ','De ','Del ','Delos ','San '];
  n  CONSTANT int := array_length(pool, 1);
  ns CONSTANT int := array_length(syl, 1);
  v text;
BEGIN
  IF random() < 0.30 THEN
    RETURN pool[1 + (floor(-ln(1 - random()) * 50)::int % n)];
  END IF;
  v := syl[1 + floor(random() * ns)::int] || syl[1 + floor(random() * ns)::int];
  IF random() < 0.6 THEN
    v := v || syl[1 + floor(random() * ns)::int];
  END IF;
  v := initcap(v);
  IF random() < 0.04 THEN
    v := pre[1 + floor(random() * array_length(pre, 1))::int] || v;
  END IF;
  RETURN v;
END;
$$;

-- -----------------------------------------------------------------------------
-- Gov-ID scrambler: replaces every digit with a random digit. Letters,
-- separators, and length are preserved, so the value keeps its format
-- (e.g. 'N1234567' -> 'N8302915', '1234-5678-9012' -> '7719-0453-2268').
-- NULL stays NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_scramble_id(p text)
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
  SELECT CASE
    WHEN p IS NULL THEN NULL
    ELSE COALESCE(
      (SELECT string_agg(
                CASE WHEN t.c ~ '^[0-9]$' THEN floor(random() * 10)::int::text ELSE t.c END,
                '' ORDER BY t.i)
         FROM unnest(string_to_array(p, NULL)) WITH ORDINALITY AS t(c, i)),
      p)
  END
$$;

-- -----------------------------------------------------------------------------
-- Birth-date jitter: same year, random day (366 in leap years). Keeps every
-- synthetic row in its original's partition and chunk while spreading rows
-- across the whole year, so months with no original rows still get synthetic
-- ones. NULL stays NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_jitter_day(p date)
RETURNS date
LANGUAGE sql
VOLATILE
AS $$
  SELECT date_trunc('year', p::timestamp)::date
         + floor(random() * ((date_trunc('year', p::timestamp) + interval '1 year')::date
                             - date_trunc('year', p::timestamp)::date))::int
$$;

-- -----------------------------------------------------------------------------
-- Chunk list shared by all procedures: one chunk per birth year in
-- [p_from, p_to), plus an optional 'outside' chunk for NULL birth dates and
-- anything outside the 1945-2015 partition range (the DEFAULT partition).
-- Predicates reference the alias "s".
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_chunks(p_from date, p_to date, p_include_outside boolean)
RETURNS TABLE (ord int, label text, pred text)
LANGUAGE sql
STABLE
AS $$
  SELECT row_number() OVER (ORDER BY y)::int,
         to_char(y, 'YYYY'),
         format('s.birth_date >= %L::date AND s.birth_date < %L::date',
                y::date, (y + interval '1 year')::date)
    FROM generate_series(date_trunc('year', p_from::timestamp),
                         p_to::timestamp - interval '1 year',
                         interval '1 year') AS y
  UNION ALL
  SELECT 1000000, 'outside',
         '(s.birth_date IS NULL OR s.birth_date < ''1945-01-01''::date OR s.birth_date >= ''2015-01-01''::date)'
   WHERE p_include_outside
  ORDER BY 1
$$;

-- -----------------------------------------------------------------------------
-- Load plan: copies per original row for every chunk of one table.
--   synthetic total  = p_copies x all original rows
--   'outside' chunk  = lt_unknown_share of the total (0 if it has no originals)
--   each birth year  = the rest x the year's weight / the summed weight of
--                      the years that have original rows. A year's weight is
--                      its band's, scaled up when some of the band's years
--                      have no original rows, so each band keeps its share.
--   copies           = that chunk's rows / its original rows, rounded
-- The plan always covers every year, so a trial over a few years uses the
-- same copies as the full run.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_plan(p_target text, p_copies int)
RETURNS TABLE (ord int, label text, pred text, birth_year int, age int,
               originals bigint, weight numeric, copies int, synthetic_rows bigint)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
DECLARE
  v_ref_year CONSTANT int := extract(year FROM current_date)::int;
  v_share    numeric;
BEGIN
  IF p_target IS NULL OR p_target NOT IN ('migrated_customers', 'customer') THEN
    RAISE EXCEPTION 'p_target must be migrated_customers or customer';
  END IF;
  IF p_copies IS NULL OR p_copies < 1 THEN
    RAISE EXCEPTION 'p_copies must be >= 1';
  END IF;

  v_share := sentinel.lt_unknown_share(p_target);
  IF v_share IS NULL OR v_share < 0 OR v_share >= 1 THEN
    RAISE EXCEPTION 'lt_unknown_share(%) must be >= 0 and < 1', p_target;
  END IF;

  IF EXISTS (SELECT 1 FROM sentinel.lt_age_curve() c
              WHERE c.age_from IS NULL OR c.age_to IS NULL OR c.weight IS NULL
                 OR c.age_from > c.age_to OR c.weight < 0) THEN
    RAISE EXCEPTION 'lt_age_curve has a band with a missing value, age_from > age_to, or a negative weight';
  END IF;
  IF EXISTS (SELECT 1 FROM sentinel.lt_age_curve() a
               JOIN sentinel.lt_age_curve() b
                 ON a.target = b.target
                AND a.age_from < b.age_from
                AND b.age_from <= a.age_to) THEN
    RAISE EXCEPTION 'lt_age_curve has overlapping bands for one target';
  END IF;

  RETURN QUERY
  WITH curve AS (
    SELECT c.age_from, c.age_to, c.weight
      FROM sentinel.lt_age_curve() c
     WHERE c.target = CASE WHEN EXISTS (SELECT 1 FROM sentinel.lt_age_curve() t
                                         WHERE t.target = p_target)
                           THEN p_target ELSE 'both' END
  ),
  counts AS (
    SELECT CASE WHEN m.birth_date >= '1945-01-01' AND m.birth_date < '2015-01-01'
                THEN extract(year FROM m.birth_date)::int END AS yr,
           count(*) AS n
      FROM sentinel.migrated_customers m
     WHERE m.ucms_record_hash IS NOT NULL
     GROUP BY 1
  ),
  chunk AS (
    SELECT k.ord, k.label, k.pred,
           CASE WHEN k.label <> 'outside' THEN k.label::int END AS yr
      FROM sentinel.lt_chunks('1945-01-01', '2015-01-01', true) k
  ),
  base AS (
    SELECT ch.ord, ch.label, ch.pred, ch.yr,
           v_ref_year - ch.yr AS age,
           COALESCE(cn.n, 0) AS n,
           cu.age_from AS band,
           CASE WHEN ch.yr IS NOT NULL THEN COALESCE(cu.weight, 0) END AS band_w
      FROM chunk ch
      LEFT JOIN counts cn ON cn.yr IS NOT DISTINCT FROM ch.yr
      LEFT JOIN curve cu ON v_ref_year - ch.yr BETWEEN cu.age_from AND cu.age_to
  ),
  -- A band's empty years hand their weight to the band's populated years.
  line AS (
    SELECT b.ord, b.label, b.pred, b.yr, b.age, b.n,
           CASE WHEN b.yr IS NULL THEN NULL
                WHEN b.n = 0      THEN b.band_w
                ELSE b.band_w * count(*) OVER band_years
                     / count(*) FILTER (WHERE b.n > 0) OVER band_years
           END AS w
      FROM base b
    WINDOW band_years AS (PARTITION BY b.band, b.yr IS NULL)
  ),
  total AS (
    SELECT p_copies::numeric * sum(l.n)                         AS synth,
           sum(l.n) FILTER (WHERE l.yr IS NULL)                 AS n_out,
           sum(l.w) FILTER (WHERE l.yr IS NOT NULL AND l.n > 0) AS w_sum
      FROM line l
  ),
  split AS (
    SELECT t.synth, t.w_sum,
           CASE WHEN t.n_out > 0 THEN t.synth * v_share ELSE 0 END AS out_rows
      FROM total t
  )
  SELECT l.ord, l.label, l.pred, l.yr, l.age, l.n, l.w,
         x.copies, x.copies::bigint * l.n
    FROM line l
   CROSS JOIN split s
   CROSS JOIN LATERAL (
     SELECT CASE
              WHEN l.n = 0         THEN 0
              WHEN l.yr IS NULL    THEN round(s.out_rows / l.n)::int
              WHEN s.w_sum > 0     THEN round((s.synth - s.out_rows) * l.w / s.w_sum / l.n)::int
              ELSE 0
            END AS copies
   ) x
   ORDER BY l.ord;
END;
$$;

-- -----------------------------------------------------------------------------
-- Load 1: sentinel.migrated_customers -> sentinel.migrated_customers
--
-- Each original row in a chunk gets that chunk's planned copies. Column list
-- is read from the catalog so every column is copied except the overrides
-- below; generated columns (full_name) are omitted and recompute.
--   migration_id      new uuid
--   first_name        random
--   last_name         random
--   birth_date        same year, random day
--   gov_id_number     digits scrambled (gov_id_type copied)
--   raw_info          copied, without er_run_timestamp, plus "lt": true
--   ucms_record_hash  NULL (keeps rows out of WS2 delta-reload DELETEs)
--   legacy_ids        NULL (no ER link to onboarded customers)
--   email, mobile_number NULL
--   created_at        now()
-- p_from / p_to select whole birth years; the copies come from the full plan.
-- A chunk that already contains synthetic rows is skipped, so the procedure
-- can be stopped and re-run without compounding.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sentinel.lt_load_migrated_customers(
  p_copies           int     DEFAULT 4,
  p_from             date    DEFAULT '1945-01-01',
  p_to               date    DEFAULT '2015-01-01',
  p_include_outside  boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_cols    text;
  v_exprs   text;
  v_chunk   record;
  v_exists  boolean;
  v_rows    bigint;
  v_total   bigint := 0;
  v_done    int := 0;
  v_skipped int := 0;
  v_empty   int := 0;
  v_t       timestamptz;
BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg(
           CASE a.attname
             WHEN 'migration_id'     THEN 'gen_random_uuid()'
             WHEN 'first_name'       THEN 'sentinel.lt_first_name()'
             WHEN 'last_name'        THEN 'sentinel.lt_last_name()'
             WHEN 'birth_date'       THEN 'sentinel.lt_jitter_day(s.birth_date)'
             WHEN 'gov_id_number'    THEN 'sentinel.lt_scramble_id(s.gov_id_number)'
             WHEN 'raw_info'         THEN '((COALESCE(s.raw_info, ''{}''::jsonb) - ''er_run_timestamp'') || ''{"lt": true}''::jsonb)'
             WHEN 'ucms_record_hash' THEN 'NULL'
             WHEN 'legacy_ids'       THEN 'NULL'
             WHEN 'email'            THEN 'NULL'
             WHEN 'mobile_number'    THEN 'NULL'
             WHEN 'created_at'       THEN 'now()'
             ELSE 's.' || quote_ident(a.attname)
           END,
           ', ' ORDER BY a.attnum)
    INTO v_cols, v_exprs
    FROM pg_attribute a
   WHERE a.attrelid = 'sentinel.migrated_customers'::regclass
     AND a.attnum > 0
     AND NOT a.attisdropped
     AND a.attgenerated = '';

  FOR v_chunk IN
    SELECT * FROM sentinel.lt_plan('migrated_customers', p_copies) p
     WHERE (p.birth_year IS NULL AND p_include_outside)
        OR (p.birth_year >= extract(year FROM p_from) AND make_date(p.birth_year, 1, 1) < p_to)
     ORDER BY p.ord
  LOOP
    v_t := clock_timestamp();

    IF v_chunk.copies = 0 THEN
      v_empty := v_empty + 1;
      CONTINUE;
    END IF;

    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM sentinel.migrated_customers s
                       WHERE %s
                         AND s.ucms_record_hash IS NULL
                         AND s.raw_info ? ''lt'')',
      v_chunk.pred)
      INTO v_exists;

    IF v_exists THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'migrated_customers %: skipped (synthetic rows present)', v_chunk.label;
      CONTINUE;
    END IF;

    EXECUTE format(
      'INSERT INTO sentinel.migrated_customers (%s)
       SELECT %s
         FROM sentinel.migrated_customers s
        CROSS JOIN generate_series(1, %s) AS g(n)
        WHERE %s
          AND s.ucms_record_hash IS NOT NULL',
      v_cols, v_exprs, v_chunk.copies, v_chunk.pred);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    COMMIT;

    v_total := v_total + v_rows;
    v_done  := v_done + 1;
    RAISE NOTICE 'migrated_customers %: % rows (x% of %) in %s (running total %)',
      v_chunk.label, v_rows, v_chunk.copies, v_chunk.originals,
      round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 1), v_total;
  END LOOP;

  RAISE NOTICE 'migrated_customers done: % chunks loaded, % skipped, % empty, % rows inserted',
    v_done, v_skipped, v_empty, v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- Load 2: sentinel.migrated_customers -> sentinel.customer
--
-- Each ORIGINAL migrated_customers row in a chunk gets that chunk's planned
-- copies from the 'customer' plan. Scalar demographics are copied; JSONB
-- groups (addresses, contact, employment, income, ...) stay NULL.
--   customer_id       new uuid
--   first_name        random
--   last_name         random
--   name_suffix       copied
--   full_name         first/middle/last/suffix joined by single spaces,
--                     skipping NULL/empty parts (write-service convention)
--   birth_date        same year, random day
--   no_middle_name    TEXT -> BOOLEAN (true/t/yes/y/1 => true, else false)
--   birth_place_country  defaults to 'PH' when empty
--   gov_id_number     digits scrambled (gov_id_type copied)
--   metadata          {"lt": true}
--   created_at, updated_at  1999-01-01 00:00:00+00 (FinCense EOD exclusion)
--   deleted_at        NULL (rows stay inside the partial indexes)
-- The inner OFFSET 0 is an optimization fence so each row's random names and
-- birth date are generated once and reused.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sentinel.lt_load_customer(
  p_copies           int     DEFAULT 4,
  p_from             date    DEFAULT '1945-01-01',
  p_to               date    DEFAULT '2015-01-01',
  p_include_outside  boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_chunk   record;
  v_exists  boolean;
  v_rows    bigint;
  v_total   bigint := 0;
  v_done    int := 0;
  v_skipped int := 0;
  v_empty   int := 0;
  v_t       timestamptz;
BEGIN
  FOR v_chunk IN
    SELECT * FROM sentinel.lt_plan('customer', p_copies) p
     WHERE (p.birth_year IS NULL AND p_include_outside)
        OR (p.birth_year >= extract(year FROM p_from) AND make_date(p.birth_year, 1, 1) < p_to)
     ORDER BY p.ord
  LOOP
    v_t := clock_timestamp();

    IF v_chunk.copies = 0 THEN
      v_empty := v_empty + 1;
      CONTINUE;
    END IF;

    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM sentinel.customer s
                       WHERE %s
                         AND s.created_at = ''1999-01-01 00:00:00+00''::timestamptz
                         AND s.metadata ? ''lt'')',
      v_chunk.pred)
      INTO v_exists;

    IF v_exists THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'customer %: skipped (synthetic rows present)', v_chunk.label;
      CONTINUE;
    END IF;

    EXECUTE format(
      'INSERT INTO sentinel.customer (
         customer_id, first_name, middle_name, last_name, name_suffix, full_name,
         alias_nickname, no_middle_name, birth_date, sex, marital_status, nationality,
         birth_place, birth_place_province, birth_place_country,
         gov_id_type, gov_id_number, metadata, created_at, updated_at)
       SELECT gen_random_uuid(),
              x.fn,
              x.middle_name,
              x.ln,
              x.name_suffix,
              concat_ws('' '', NULLIF(x.fn, ''''), NULLIF(x.middle_name, ''''), NULLIF(x.ln, ''''),
                        NULLIF(x.name_suffix, '''')),
              x.alias_nickname,
              COALESCE(lower(btrim(x.no_middle_name)) IN (''true'', ''t'', ''yes'', ''y'', ''1''), false),
              x.birth_date,
              x.sex,
              x.marital_status,
              x.nationality,
              x.birth_place,
              x.birth_place_province,
              COALESCE(NULLIF(x.birth_place_country, ''''), ''PH''),
              x.gov_id_type,
              sentinel.lt_scramble_id(x.gov_id_number),
              ''{"lt": true}''::jsonb,
              ''1999-01-01 00:00:00+00''::timestamptz,
              ''1999-01-01 00:00:00+00''::timestamptz
         FROM (
           SELECT s.middle_name, s.name_suffix, s.alias_nickname, s.no_middle_name,
                  sentinel.lt_jitter_day(s.birth_date) AS birth_date, s.sex,
                  s.marital_status, s.nationality, s.birth_place, s.birth_place_province,
                  s.birth_place_country, s.gov_id_type, s.gov_id_number,
                  sentinel.lt_first_name() AS fn,
                  sentinel.lt_last_name()  AS ln
             FROM sentinel.migrated_customers s
            CROSS JOIN generate_series(1, %s) AS g(n)
            WHERE %s
              AND s.ucms_record_hash IS NOT NULL
           OFFSET 0
         ) AS x',
      v_chunk.copies, v_chunk.pred);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    COMMIT;

    v_total := v_total + v_rows;
    v_done  := v_done + 1;
    RAISE NOTICE 'customer %: % rows (x% of %) in %s (running total %)',
      v_chunk.label, v_rows, v_chunk.copies, v_chunk.originals,
      round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 1), v_total;
  END LOOP;

  RAISE NOTICE 'customer done: % chunks loaded, % skipped, % empty, % rows inserted',
    v_done, v_skipped, v_empty, v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- Cleanup: deletes synthetic rows from both tables, one birth-year chunk per
-- transaction. Always covers the full range plus the outside chunk.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sentinel.lt_cleanup()
LANGUAGE plpgsql
AS $$
DECLARE
  v_chunk record;
  v_mc    bigint;
  v_c     bigint;
  v_mc_total bigint := 0;
  v_c_total  bigint := 0;
BEGIN
  FOR v_chunk IN SELECT * FROM sentinel.lt_chunks('1945-01-01', '2015-01-01', true) LOOP
    EXECUTE format(
      'DELETE FROM sentinel.migrated_customers s
        WHERE %s
          AND s.ucms_record_hash IS NULL
          AND s.legacy_ids IS NULL
          AND s.raw_info ? ''lt''',
      v_chunk.pred);
    GET DIAGNOSTICS v_mc = ROW_COUNT;

    EXECUTE format(
      'DELETE FROM sentinel.customer s
        WHERE %s
          AND s.created_at = ''1999-01-01 00:00:00+00''::timestamptz
          AND s.metadata ? ''lt''',
      v_chunk.pred);
    GET DIAGNOSTICS v_c = ROW_COUNT;

    COMMIT;

    v_mc_total := v_mc_total + v_mc;
    v_c_total  := v_c_total + v_c;
    IF v_mc > 0 OR v_c > 0 THEN
      RAISE NOTICE 'cleanup %: migrated_customers %, customer %', v_chunk.label, v_mc, v_c;
    END IF;
  END LOOP;

  RAISE NOTICE 'cleanup done: migrated_customers %, customer % rows deleted', v_mc_total, v_c_total;
END;
$$;
