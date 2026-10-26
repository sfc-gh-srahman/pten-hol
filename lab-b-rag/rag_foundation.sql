-- Lab B: the shared retrieval foundation (B2) and the managed level (B4).
-- Upload first (notebook does this with session.file.put, or):
--   snow stage copy lab-b-rag/docs/*.pdf @HOL_PTEN_ML.DOCS.RAW_DOCS/samples/ -c <conn>
USE WAREHOUSE HOL_PTEN_WH;
USE SCHEMA HOL_PTEN_ML.DOCS;
ALTER STAGE HOL_PTEN_ML.DOCS.RAW_DOCS REFRESH;

-- B2.1 Parse: layout-aware text from every PDF on the stage
CREATE OR REPLACE TABLE HOL_PTEN_ML.DOCS.PARSED_DOCS AS
SELECT relative_path,
       SPLIT_PART(relative_path, '/', -1) AS file_name,
       AI_PARSE_DOCUMENT(TO_FILE('@HOL_PTEN_ML.DOCS.RAW_DOCS', relative_path), {'mode': 'LAYOUT'}):content::STRING AS content
FROM DIRECTORY(@HOL_PTEN_ML.DOCS.RAW_DOCS)
WHERE relative_path ILIKE '%.pdf';

-- B2.2 Chunk: markdown-aware splitting, ~1,500 characters with overlap
CREATE OR REPLACE TABLE HOL_PTEN_ML.DOCS.DOC_CHUNKS AS
SELECT p.relative_path, p.file_name,
       INITCAP(REPLACE(REPLACE(p.file_name, '.pdf', ''), '_', ' ')) AS title,
       c.index AS chunk_index, c.value::STRING AS chunk
FROM HOL_PTEN_ML.DOCS.PARSED_DOCS p,
     LATERAL FLATTEN(SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(p.content, 'markdown', 1500, 200)) c;

-- B2.3 Index: hybrid (vector + keyword) search; embeddings handled by the service
CREATE OR REPLACE CORTEX SEARCH SERVICE HOL_PTEN_ML.DOCS.DRILLING_DOCS_SEARCH
  ON chunk
  ATTRIBUTES title, file_name
  WAREHOUSE = HOL_PTEN_WH
  TARGET_LAG = '1 hour'
  AS SELECT chunk, title, file_name, relative_path, chunk_index FROM HOL_PTEN_ML.DOCS.DOC_CHUNKS;

-- Quick test from SQL
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('HOL_PTEN_ML.DOCS.DRILLING_DOCS_SEARCH',
  '{"query": "early warning signs of stuck pipe", "columns": ["title", "chunk"], "limit": 2}')):results AS results;
