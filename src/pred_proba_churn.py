import  os
import  json
import  logging
import  pandas as pd
import  joblib
from    datetime import datetime
from    config_db import obter_engine_banco


# CONFIGURAÇÕES DE CAMINHOS E DIRETÓRIOS (ORQUESTRAÇÃO)
CAMINHO_SRC     = os.path.dirname(os.path.abspath(__file__))    # Pasta /src
RAIZ_PROJETO    = os.path.dirname(CAMINHO_SRC)                  # Pasta raiz

# Mapeamento dos artefatos de /src
NOME_MODELO             = 'xgb_tuning'
ARQUIVO_PIPELINE_PKL    = f"pipeline_{NOME_MODELO}.pkl"
CAMINHO_PIPELINE_PKL    = os.path.join(CAMINHO_SRC, ARQUIVO_PIPELINE_PKL)
CAMINHO_FEATURES_JSON   = os.path.join(CAMINHO_SRC, 'features_modelo.json')

# Direcionamento do Log e do Resultado para as pastas corretas
CAMINHO_LOG_ARQUIVO   = os.path.join(CAMINHO_SRC,  "execucao_churn.log")
PASTA_RESULTADOS      = os.path.join(RAIZ_PROJETO, "dados_resultado")

# Mapeamento dinâmico do arquivo SQL na pasta dados_brutos
CAMINHO_QUERY_SQL     = os.path.join(RAIZ_PROJETO, "dados_brutos", "tarefas_clientes_ativos_producao.sql")

# CONFIGURAÇÃO DO LOG
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(CAMINHO_LOG_ARQUIVO, encoding='utf-8'),
        logging.StreamHandler()
    ]
)

def executar_pipeline_predicao():
    logging.info("%s", "*" * 50)
    logging.info("INICIANDO PIPELINE DE PREDIÇÃO DE CHURN - %s", NOME_MODELO)

    # CARREGAMENTO DOS ARTEFATOS DO MODELO
    try:
        logging.info("Carregando pipeline: %s", ARQUIVO_PIPELINE_PKL)
        pipeline = joblib.load(CAMINHO_PIPELINE_PKL)
    except Exception:
        logging.error("Falha crítica no carregamento do pipeline .pkl")
        return

    # LEITURA DO JSON DE FEATURES
    try:
        logging.info("Lendo features em: %s", os.path.basename(CAMINHO_FEATURES_JSON))
        with open(CAMINHO_FEATURES_JSON, 'r', encoding='utf-8') as f:
            features_modelo = json.load(f)
        logging.info("Sucesso! %d features mapeadas do JSON.", len(features_modelo))
    except FileNotFoundError as e:
        logging.error("Falha ao ler o arquivo de mapeamento JSON: %s", e)
        return

    # EXTRAÇÃO DOS DADOS BRUTOS (SQL)
    try:
        logging.info("Carregando query de extração: %s", os.path.basename(CAMINHO_QUERY_SQL))
        with open(CAMINHO_QUERY_SQL, 'r', encoding='utf-8') as f:
            query_sql = f.read()

        query_tratada = query_sql.replace('%', '%%')

        logging.info("Conectando ao banco de dados e executando extração...")
        engine      = obter_engine_banco()
        df_bruto    = pd.read_sql(query_tratada, con=engine)
        print(df_bruto.filter(regex='casa').columns)
        logging.info("Extração concluída com sucesso.")
    except Exception:
        logging.exception("Erro na fase de comunicação/extração do banco de dados")
        return

    # VALIDAÇÃO DEFENSIVA E ALINHAMENTO DO DATASET
    try:
        logging.info("Iniciando validação de consistência das colunas...")

        # Identifica se alguma coluna exigida pelo modelo não veio na extração do banco
        colunas_faltantes = [col for col in features_modelo if col not in df_bruto.columns]
        if colunas_faltantes:
            raise KeyError(f"As seguintes colunas exigidas pelo modelo estão ausentes no banco: {colunas_faltantes}")

        # Filtra e ordena as colunas exatamente na ordem estrita que o modelo espera
        x_inferencia = df_bruto[features_modelo].copy()

        logging.info("Estrutura da Matriz de Inferência (X) validada e alinhada com sucesso.")
    except KeyError as e:
        logging.error("Quebra de consistência nos dados de entrada: %s", e)
    except Exception:
        logging.exception("Erro inesperado na validação dos dados")
        return

    # EXECUÇÃO DO PROCESSO PREDIÇÃO VIA PIPELINE
    try:
        logging.info("Calculando probabilidades via pipeline...")
        # O pipeline aplica o scaler automaticamente e depois o modelo
        probabilidades = pipeline.predict_proba(x_inferencia)[:, 1]
    except Exception:
        logging.exception("Falha durante a predição")
        return

    # ESTRUTURAÇÃO DO RELATÓRIO EXECUTIVO DE SAÍDA
    try:
        logging.info("Adicionando resultados ao contexto analítico do cliente...")
        df_final = df_bruto.copy()

        df_final['risco_churn_percentual'] = probabilidades

        # Formatação e arredondamentos para evitar sujeira visual no Excel
        df_final['risco_churn_percentual'] = df_final['risco_churn_percentual'].round(2)
        df_final['media_dias_exec']        = df_final['media_dias_exec'].round(1)

        if 'media_dias_exec_reclamacao' in df_final.columns:
            df_final['media_dias_exec_reclamacao'] = df_final['media_dias_exec_reclamacao'].round(1)

        # Ordenação por prioridade dos maiores riscos da carteira
        df_final = df_final.sort_values(by=['risco_churn_percentual'], ascending=False)
        logging.info("Predição realizada e colunas de contexto adicionadas com sucesso.")
    except Exception:
        logging.exception("Erro durante a fase de estruturação do DataFrame final")
        return

    # EXPORTAÇÃO PROTEGIDA PARA /DADOS_RESULTADO
    try:
        os.makedirs(PASTA_RESULTADOS, exist_ok=True)
        data_atual          = datetime.now().strftime("%Y-%m-%d")
        nome_arquivo        = f"relatorio_risco_churn_{NOME_MODELO}_{data_atual}.xlsx"
        caminho_salvamento  = os.path.join(PASTA_RESULTADOS, nome_arquivo)
        logging.info("Salvando relatório executivo final em: %s", caminho_salvamento)

        df_final.to_excel(caminho_salvamento, index=False, engine='openpyxl')
        logging.info("PIPELINE EXECUTADO COM SUCESSO.")

    except Exception:
        logging.exception("Falha ao persistir arquivo de saída")
        return

if __name__ == "__main__":
    executar_pipeline_predicao()
