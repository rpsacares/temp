-- =============================================================================
-- Load-test weight data: setup
--
-- Creates helper functions and procedures that inflate
-- sentinel.migrated_customers and sentinel.customer with synthetic rows so the
-- trigram GIN indexes (first_name, last_name, full_name) and the birth_date
-- partitions carry realistic weight. Rows are not meant to be searched.
--
-- Every synthetic row is marked by name_suffix = 'LT' (also visible in
-- full_name). Secondary guards used by cleanup:
--   migrated_customers: ucms_record_hash IS NULL AND legacy_ids IS NULL
--   customer:           created_at = 1999-01-01 00:00:00+00
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
--   * PostgreSQL 12+ (pg_attribute.attgenerated).
-- SIT / non-production only.
-- =============================================================================

\set ON_ERROR_STOP on

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
-- Chunk list shared by all procedures: one chunk per birth month in
-- [p_from, p_to), plus an optional 'outside' chunk for NULL birth dates and
-- anything outside the 1945-2015 partition range (the DEFAULT partition).
-- Predicates reference the alias "s".
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sentinel.lt_chunks(p_from date, p_to date, p_include_outside boolean)
RETURNS TABLE (ord int, label text, pred text)
LANGUAGE sql
STABLE
AS $$
  SELECT row_number() OVER (ORDER BY m)::int,
         to_char(m, 'YYYY-MM'),
         format('s.birth_date >= %L::date AND s.birth_date < %L::date',
                m::date, (m + interval '1 month')::date)
    FROM generate_series(date_trunc('month', p_from::timestamp),
                         p_to::timestamp - interval '1 month',
                         interval '1 month') AS m
  UNION ALL
  SELECT 1000000, 'outside',
         '(s.birth_date IS NULL OR s.birth_date < ''1945-01-01''::date OR s.birth_date >= ''2015-01-01''::date)'
   WHERE p_include_outside
  ORDER BY 1
$$;

-- -----------------------------------------------------------------------------
-- Load 1: sentinel.migrated_customers -> sentinel.migrated_customers
--
-- p_copies synthetic rows per original row. Column list is read from the
-- catalog so every column is copied except the overrides below; the
-- generated full_name column is omitted and recomputes from the new names.
--   migration_id      new uuid
--   first_name        random
--   last_name         random
--   name_suffix       'LT'
--   gov_id_number     digits scrambled (gov_id_type copied)
--   ucms_record_hash  NULL (keeps rows out of WS2 delta-reload DELETEs)
--   legacy_ids        NULL (no ER link to onboarded customers)
--   email, mobile_number NULL
--   created_at        now()
-- A chunk that already contains 'LT' rows is skipped, so the procedure can be
-- stopped and re-run without compounding.
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
  IF p_copies IS NULL OR p_copies < 1 THEN
    RAISE EXCEPTION 'p_copies must be >= 1';
  END IF;

  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg(
           CASE a.attname
             WHEN 'migration_id'     THEN 'gen_random_uuid()'
             WHEN 'first_name'       THEN 'sentinel.lt_first_name()'
             WHEN 'last_name'        THEN 'sentinel.lt_last_name()'
             WHEN 'name_suffix'      THEN '''LT'''
             WHEN 'gov_id_number'    THEN 'sentinel.lt_scramble_id(s.gov_id_number)'
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

  FOR v_chunk IN SELECT * FROM sentinel.lt_chunks(p_from, p_to, p_include_outside) LOOP
    v_t := clock_timestamp();

    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM sentinel.migrated_customers s WHERE %s AND s.name_suffix = ''LT'')',
      v_chunk.pred)
      INTO v_exists;

    IF v_exists THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'migrated_customers %: skipped (LT rows present)', v_chunk.label;
      CONTINUE;
    END IF;

    EXECUTE format(
      'INSERT INTO sentinel.migrated_customers (%s)
       SELECT %s
         FROM sentinel.migrated_customers s
        CROSS JOIN generate_series(1, %s) AS g(n)
        WHERE %s
          AND s.name_suffix IS DISTINCT FROM ''LT''',
      v_cols, v_exprs, p_copies, v_chunk.pred);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    COMMIT;

    IF v_rows = 0 THEN
      v_empty := v_empty + 1;
      CONTINUE;
    END IF;

    v_total := v_total + v_rows;
    v_done  := v_done + 1;
    RAISE NOTICE 'migrated_customers %: % rows in %s (running total %)',
      v_chunk.label, v_rows,
      round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 1), v_total;
  END LOOP;

  RAISE NOTICE 'migrated_customers done: % chunks loaded, % skipped, % empty, % rows inserted',
    v_done, v_skipped, v_empty, v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- Load 2: sentinel.migrated_customers -> sentinel.customer
--
-- p_copies synthetic customer rows per ORIGINAL migrated_customers row (LT
-- rows are never used as a source). Scalar demographics are copied; JSONB
-- groups (addresses, contact, employment, income, ...) stay NULL.
--   customer_id       new uuid
--   first_name        random
--   last_name         random
--   name_suffix       'LT'
--   full_name         first/middle/last/suffix joined by single spaces,
--                     skipping NULL/empty parts (write-service convention)
--   no_middle_name    TEXT -> BOOLEAN (true/t/yes/y/1 => true, else false)
--   birth_place_country  defaults to 'PH' when empty
--   gov_id_number     digits scrambled (gov_id_type copied)
--   metadata          '{}'
--   created_at, updated_at  1999-01-01 00:00:00+00 (FinCense EOD exclusion)
--   deleted_at        NULL (rows stay inside the partial indexes)
-- The inner OFFSET 0 is an optimization fence so each row's random names are
-- generated once and reused for first_name, last_name, and full_name.
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
  IF p_copies IS NULL OR p_copies < 1 THEN
    RAISE EXCEPTION 'p_copies must be >= 1';
  END IF;

  FOR v_chunk IN SELECT * FROM sentinel.lt_chunks(p_from, p_to, p_include_outside) LOOP
    v_t := clock_timestamp();

    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM sentinel.customer s
                       WHERE %s
                         AND s.name_suffix = ''LT''
                         AND s.created_at = ''1999-01-01 00:00:00+00''::timestamptz)',
      v_chunk.pred)
      INTO v_exists;

    IF v_exists THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'customer %: skipped (LT rows present)', v_chunk.label;
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
              ''LT'',
              concat_ws('' '', NULLIF(x.fn, ''''), NULLIF(x.middle_name, ''''), NULLIF(x.ln, ''''), ''LT''),
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
              ''{}''::jsonb,
              ''1999-01-01 00:00:00+00''::timestamptz,
              ''1999-01-01 00:00:00+00''::timestamptz
         FROM (
           SELECT s.middle_name, s.alias_nickname, s.no_middle_name, s.birth_date, s.sex,
                  s.marital_status, s.nationality, s.birth_place, s.birth_place_province,
                  s.birth_place_country, s.gov_id_type, s.gov_id_number,
                  sentinel.lt_first_name() AS fn,
                  sentinel.lt_last_name()  AS ln
             FROM sentinel.migrated_customers s
            CROSS JOIN generate_series(1, %s) AS g(n)
            WHERE %s
              AND s.name_suffix IS DISTINCT FROM ''LT''
           OFFSET 0
         ) AS x',
      p_copies, v_chunk.pred);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    COMMIT;

    IF v_rows = 0 THEN
      v_empty := v_empty + 1;
      CONTINUE;
    END IF;

    v_total := v_total + v_rows;
    v_done  := v_done + 1;
    RAISE NOTICE 'customer %: % rows in %s (running total %)',
      v_chunk.label, v_rows,
      round(extract(epoch FROM clock_timestamp() - v_t)::numeric, 1), v_total;
  END LOOP;

  RAISE NOTICE 'customer done: % chunks loaded, % skipped, % empty, % rows inserted',
    v_done, v_skipped, v_empty, v_total;
END;
$$;

-- -----------------------------------------------------------------------------
-- Cleanup: deletes synthetic rows from both tables, one birth-month chunk per
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
          AND s.name_suffix = ''LT''
          AND s.ucms_record_hash IS NULL
          AND s.legacy_ids IS NULL',
      v_chunk.pred);
    GET DIAGNOSTICS v_mc = ROW_COUNT;

    EXECUTE format(
      'DELETE FROM sentinel.customer s
        WHERE %s
          AND s.name_suffix = ''LT''
          AND s.created_at = ''1999-01-01 00:00:00+00''::timestamptz',
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
