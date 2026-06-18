-- SEED LOCAL — NÃO usar em produção.
-- Insere a chave de API que o evaluation-service usa (SERVICE_API_KEY do .env)
-- para que o fluxo de avaliação funcione localmente sem passo manual.
-- O valor abaixo é o hash SHA-256 da chave em texto plano que está no .env.
-- Este arquivo é montado SOMENTE pelo docker-compose local (não pelo schema de produção).

INSERT INTO api_keys (name, key_hash)
VALUES ('evaluation-service-local', '3e1751baf9755a5ab9f833adb83410458e1dc92d0838a5f295e23f21e6c2499f')
ON CONFLICT (key_hash) DO NOTHING;
