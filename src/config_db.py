import  os
import  logging
from    dotenv import load_dotenv
from    sqlalchemy import create_engine


# Carrega as variáveis do arquivo .env para o sistema
CAMINHO_SCRIPT  = os.path.dirname(os.path.abspath(__file__)) # pasta /src
RAIZ_PROJETO    = os.path.dirname(CAMINHO_SCRIPT)            # pasta raiz
CAMINHO_ENV     = os.path.join(RAIZ_PROJETO, ".env")

# Carrega especificamente o arquivo .env localizado na raiz
load_dotenv(dotenv_path=CAMINHO_ENV)


def obter_engine_banco():
    """Lê as credenciais seguras do .env e retorna o engine de conexão."""
    user        = os.getenv("DB_USER")
    password    = os.getenv("DB_PASS")
    host        = os.getenv("DB_HOST")
    port        = os.getenv("DB_PORT")
    schema      = os.getenv("DB_NAME")

    if not all([user, password, host, schema]):
        logging.error("🚨 Variáveis de ambiente de banco de dados não encontradas no .env!")
        raise ValueError("Configurações do .env ausentes ou incompletas.")
        
    url_conexao = f"mysql+pymysql://{user}:{password}@{host}:{port}/{schema}"
    logging.info("✅ Parâmetros de conexão estruturados com sucesso!")

    return create_engine(url_conexao, pool_recycle=3600)

# BLOCO DE TESTE
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    try:
        engine = obter_engine_banco()
        with engine.connect() as conn:
            print("🚀 SUCESSO! Conexão com o MySQL realizada e validada!")
    except Exception as e:
        print(f"❌ FALHA NO TESTE: {str(e)}")