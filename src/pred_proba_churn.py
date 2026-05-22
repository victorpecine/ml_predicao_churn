import  os
import  json
import  logging
import  pandas as pd
import  joblib
from    datetime import datetime
from    config_db import obter_engine_banco


CAMINHO_SRC     = os.path.dirname(os.path.abspath(__file__))    # pasta /src
RAIZ_PROJETO    = os.path.dirname(CAMINHO_SRC)                  # pasta raiz

# Mapeamento dos artefatos dentro de /src
NOME_MODELO             = 'modelo_xgb'
ARQUIVO_MODELO_PKL      = f"{NOME_MODELO}.pkl"
CAMINHO_MODELO_PKL      = os.path.join(CAMINHO_SRC, ARQUIVO_MODELO_PKL)
CAMINHO_SCALER_PKL      = os.path.join(CAMINHO_SRC, 'scaler_producao.pkl')
CAMINHO_FEATURES_JSON   = os.path.join(CAMINHO_SRC, 'features_modelo.json')

# Direcionamento do Log e do Resultado para as pastas corretas
CAMINHO_LOG_ARQUIVO   = os.path.join(CAMINHO_SRC, "execucao_churn.log")
PASTA_RESULTADOS      = os.path.join(RAIZ_PROJETO, "dados_resultado")

# Mapeamento dinâmico do arquivo SQL na pasta dados_brutos
CAMINHO_QUERY_SQL     = os.path.join(RAIZ_PROJETO, "dados_brutos", "tarefas_clientes_ativos_logistic_regression.sql")

# Configuração básica de logs
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.FileHandler(CAMINHO_LOG_ARQUIVO, encoding='utf-8'), logging.StreamHandler()]
)

def carregar_query_producao(caminho_sql):
    """Lê o arquivo .sql externo de forma segura e escapa os caracteres '%' para o Python."""
    if not os.path.exists(caminho_sql):
        raise FileNotFoundError(f"Arquivo de query não encontrado em: {caminho_sql}")
    
    with open(caminho_sql, 'r', encoding='utf-8') as f:
        query = f.read()
    
    # Escapa os '%' duplicando-os, transformando '%bug%' em '%%bug%%' para o motor do SQLAlchemy
    return query.replace("%", "%%")

def executar_pipeline_producao():
    logging.info(f"\n{'*' * 40}\nIniciando rotina diária de probabilidade de Churn...")
    
    # Carregamento de Artefatos com Caminhos Absolutos
    try:
        model  = joblib.load(CAMINHO_MODELO_PKL)
        scaler = joblib.load(CAMINHO_SCALER_PKL)
        with open(CAMINHO_FEATURES_JSON, 'r', encoding='utf-8') as f:
            features_obrigatorias = json.load(f)

        # Leitura dinâmica da query externa
        query_clientes_ativos = carregar_query_producao(CAMINHO_QUERY_SQL)
                
        logging.info("Artefatos do modelo e query SQL carregados com sucesso.")
    except Exception as e:
        logging.error(f"Erro ao carregar arquivos de configuração/modelo: {str(e)}")
        return

    # Extração Isolada do Banco
    try:
        engine = obter_engine_banco()
        with engine.connect() as conexao:
            logging.info("Conectando e extraindo clientes ativos...")
            df_banco = pd.read_sql(query_clientes_ativos, conexao)
        logging.info(f"Dados extraídos com sucesso. Registros: {len(df_banco)}")
    except Exception as e:
        logging.error(f"Falha na extração de dados: {str(e)}")
        return

    # Blindagem de Schema
    try:
        if df_banco.empty:
            raise ValueError("O DataFrame retornado pelo banco está vazio.")
            
        colunas_faltantes = set(features_obrigatorias) - set(df_banco.columns)
        if colunas_faltantes:
            raise ValueError(f"Incompatibilidade de Schema! Colunas ausentes: {colunas_faltantes}")

        X_producao          = df_banco[features_obrigatorias]
        codigos_clientes    = df_banco['cod_cliente']
    except Exception as e:
        logging.error(f"Falha na validação estrutural: {str(e)}")
        return

    # Predição
    try:
        X_producao_scaled   = scaler.transform(X_producao)
        probabilidades      = model.predict_proba(X_producao_scaled)[:, 1]
        
        # 1. Montamos o DataFrame Final puxando as métricas preditas e os dados de contexto do df_banco
        df_final = pd.DataFrame({
            'cod_cliente':              codigos_clientes,
            'risco_churn_percentual':   probabilidades,
            
            # Contexto Financeiro e Contratual (essencial para o CS priorizar por receita!)
            'valor_mensal_ativo':   df_banco['valor_ativo_total'],
            'qtd_contratos_ativos': df_banco['qtd_contratos_ativos'].astype(int),
            'ja_sofreu_downgrade':  df_banco['flag_ja_sofreu_downgrade'].astype(int),
            
            # Comportamento e Engajamento Recente vs Histórico
            'dias_sem_abrir_chamado':       X_producao['dias_ultima_tarefa'].astype(int),
            # 'chamados_ultimos_90_dias':     df_banco['tarefas_90d'].astype(int),
            'total_chamados_historico':     df_banco['qtd_tarefas_total'].astype(int),
            'media_dias_resolucao_chamado': df_banco['media_dias_exec'],
            
            # Alertas Críticos de Atrito
            'qt_chamados_bug':                  X_producao['qt_tarefas_bug'].astype(int),
            'qt_chamados_reclamacao':           X_producao['qt_tarefas_reclamacao'].astype(int),
            'media_dias_resolucao_reclamacao':  df_banco['media_dias_exec_reclamacao']
        })
        
        # 2. Arredondamentos sênior do Pandas para o Excel ficar limpo
        df_final['risco_churn_percentual']          = df_final['risco_churn_percentual'].astype(float).round(2)
        # df_final['meses_de_casa']                   = df_final['meses_de_casa'].round(1)
        df_final['valor_mensal_ativo']              = df_final['valor_mensal_ativo'].round(2)
        df_final['media_dias_resolucao_chamado']    = df_final['media_dias_resolucao_chamado'].round(1)
        df_final['media_dias_resolucao_reclamacao'] = df_final['media_dias_resolucao_reclamacao'].round(1)
        
        # 3. Ordenamos do maior risco para o menor (e em caso de empate, pelo maior valor de contrato)
        df_final = df_final.sort_values(by=['risco_churn_percentual', 'valor_mensal_ativo'], ascending=[False, False])
        
        logging.info("Predição realizada e colunas de contexto acopladas com sucesso.")
    except Exception as e:
        logging.error(f"Erro durante a fase de predição/estruturação: {str(e)}")
        return

    # Exportação Protegida para /dados_resultado
    try:
        # Cria a pasta caso ela não exista no servidor
        os.makedirs(PASTA_RESULTADOS, exist_ok=True)
        
        data_atual          = datetime.now().strftime("%Y-%m-%d")
        nome_arquivo        = f"relatorio_risco_churn_{NOME_MODELO}_{data_atual}.xlsx"
        caminho_salvamento  = os.path.join(PASTA_RESULTADOS, nome_arquivo)
        
        df_final.to_excel(caminho_salvamento, index=False)
        logging.info(f"🚀 SUCESSO! Relatório diário gerado e salvo em: {caminho_salvamento}")
    except Exception as e:
        logging.error(f"Erro ao salvar arquivo de saída: {str(e)}")

if __name__ == "__main__":
    executar_pipeline_producao()