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
NOME_MODELO             = 'modelo_rf'
ARQUIVO_MODELO_PKL      = f"{NOME_MODELO}.pkl"
CAMINHO_MODELO_PKL      = os.path.join(CAMINHO_SRC, ARQUIVO_MODELO_PKL)
CAMINHO_SCALER_PKL      = os.path.join(CAMINHO_SRC, 'scaler_producao.pkl')
CAMINHO_FEATURES_JSON   = os.path.join(CAMINHO_SRC, 'features_modelo.json')

# Direcionamento do Log e do Resultado para as pastas corretas
CAMINHO_LOG_ARQUIVO   = os.path.join(CAMINHO_SRC, "execucao_churn.log")
PASTA_RESULTADOS      = os.path.join(RAIZ_PROJETO, "dados_resultado")

# Configuração básica de logs
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.FileHandler(CAMINHO_LOG_ARQUIVO, encoding='utf-8'), logging.StreamHandler()]
)

QUERY_CLIENTES_ATIVOS = """
    WITH tb_clientes AS (
        SELECT
            cct.codigo AS cod_cliente,
            MIN(DATE(cct.assinatura)) AS primeira_assinatura,
            MAX(CASE WHEN cct.status = 4 THEN DATE(COALESCE(cct.cancelamento, cct.vencimento)) ELSE NULL END) AS data_ultimo_cancelamento,
            SUM(CASE WHEN cct.status = 3 THEN cct.valor_contrato ELSE 0 END) AS valor_ativo_total,
            SUM(CASE WHEN cct.status = 4 THEN cct.valor_contrato ELSE 0 END) AS valor_cancelado_total,
            SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) AS qtd_contratos_ativos,
            SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) AS qtd_contratos_cancelados,
            CASE WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS flg_ja_sofreu_downgrade,
            CASE WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END AS churn
        FROM gecobi2.consolida_contratos cct
        WHERE cct.assinatura IS NOT NULL
        AND cct.status IN (3, 4)
        GROUP BY cct.codigo
        HAVING qtd_contratos_ativos > 0
    ),
    tb_tarefas AS (
        SELECT
            otb.cliente AS cod_cliente,
            otb.data_cad,
            otb.data_exe,
            DATEDIFF(otb.data_exe, otb.data_cad) AS dias_exec_tarefa,
            otb.categoria,
            stv1.dst AS descr_categoria,
            otb.subcategoria,
            stv2.dst AS descr_subcategoria,
            otb.prioridade,
            CASE WHEN utb.grupo_trabalho IN (3, 29, 64) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad) ELSE NULL END AS dias_exec_tarefa_sd,
            CASE WHEN utb.grupo_trabalho IN (5, 23, 63) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad) ELSE NULL END AS dias_exec_tarefa_hd,
            CASE WHEN otb.categoria IN (304) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad) ELSE NULL END AS dias_exec_tarefa_reclamacao,
            CASE WHEN otb.categoria IN (18402, 18441, 18468) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad) ELSE NULL END AS dias_exec_tarefa_reducao,
            CASE WHEN (LOWER(stv1.dst) LIKE '%%bug%%' OR LOWER(stv2.dst) LIKE '%%bug%%') AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad) ELSE NULL END AS dias_exec_tarefa_bug,
            utb.grupo_trabalho
        FROM gecobi2.ordemser_tb otb
        LEFT JOIN gecobi2.stos_tb sto ON otb.stos = sto.cod
        LEFT JOIN gecobi2.usu_tb utb ON otb.para1 = utb.cod_usu
        LEFT JOIN gecobi2.stven_tb stv1 ON otb.categoria = stv1.st
        LEFT JOIN gecobi2.stven_tb stv2 ON otb.subcategoria = stv2.st
        WHERE otb.nros_sub = 0 
        AND otb.stos NOT IN ('CAN', 'PGE')
        AND LOWER(COALESCE(stv1.dst, '')) NOT LIKE '%%cancel%%'
        AND LOWER(COALESCE(stv2.dst, '')) NOT LIKE '%%cancel%%'
        AND otb.categoria NOT IN (210, 224, 225, 352, 367, 16375, 15693, 17367, 17536, 18327, 21486)
        AND sto.descr NOT LIKE '%%RETORNO%%'
    ),
    tb_features AS (
        SELECT
            t.cod_cliente,
            COUNT(*) AS qtd_tarefas_total,
            MAX(t.data_cad) AS data_ultima_tarefa_real,
            SUM(CASE WHEN t.data_cad >= CURDATE() - INTERVAL 90 DAY THEN 1 ELSE 0 END) AS tarefas_90d,
            AVG(t.dias_exec_tarefa) AS media_dias_exec,
            AVG(t.dias_exec_tarefa_sd) AS media_dias_exec_tarefa_sd,
            AVG(t.dias_exec_tarefa_hd) AS media_dias_exec_tarefa_hd,
            AVG(t.dias_exec_tarefa_reclamacao) AS media_dias_exec_reclamacao,
            AVG(t.dias_exec_tarefa_reducao) AS media_dias_exec_reducao,
            AVG(t.dias_exec_tarefa_bug) AS media_dias_exec_bug,
            COUNT(DISTINCT t.categoria) AS qtd_categorias_distintas,
            COUNT(DISTINCT t.subcategoria) AS qtd_subcategorias_distintas,
            COUNT(DISTINCT t.grupo_trabalho) AS qtd_grupos_envolvidos,
            SUM(CASE WHEN t.grupo_trabalho IN (3,29, 64) THEN 1 ELSE 0 END) AS qt_tarefas_sd,
            SUM(CASE WHEN t.grupo_trabalho IN (5, 23, 63) THEN 1 ELSE 0 END) AS qt_tarefas_hd,
            SUM(CASE WHEN t.categoria IN (304) THEN 1 ELSE 0 END) AS qt_tarefas_reclamacao,
            SUM(CASE WHEN t.categoria IN (18402, 18441, 18468) THEN 1 ELSE 0 END) AS qt_tarefas_reducao,
            SUM(CASE WHEN LOWER(t.descr_categoria) LIKE '%%bug%%' OR LOWER(t.descr_subcategoria) LIKE '%%bug%%' THEN 1 ELSE 0 END) AS qt_tarefas_bug,
            SUM(CASE WHEN t.prioridade IN (0,1) THEN 1 ELSE 0 END) AS qtd_prioridade_normal,
            SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END) AS qtd_prioridade_parcial,
            SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END) AS qtd_prioridade_urgente,
            SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) AS qtd_prioridade_maxima,
            SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END) AS qtd_prioridade_reforco,
            SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) / COUNT(*) AS perc_prioridade_maxima,
            DATEDIFF(CURDATE(), MIN(t.data_cad)) / 30.4 AS meses_de_casa
        FROM tb_tarefas t
        GROUP BY t.cod_cliente
    )
    SELECT
        c.cod_cliente,
        c.valor_ativo_total,
        c.valor_cancelado_total,
        c.qtd_contratos_ativos,
        c.qtd_contratos_cancelados,
        c.flg_ja_sofreu_downgrade,
        COALESCE(f.tarefas_90d, 0) AS tarefas_90d,
        COALESCE(f.qtd_tarefas_total, 0) AS qtd_tarefas_total,
        COALESCE(f.media_dias_exec, 0) AS media_dias_exec,
        COALESCE(f.qt_tarefas_sd, 0) AS qt_tarefas_sd,
        COALESCE(f.media_dias_exec_tarefa_sd, 0) AS media_dias_exec_tarefa_sd,
        COALESCE(f.qt_tarefas_hd, 0) AS qt_tarefas_hd,
        COALESCE(f.media_dias_exec_tarefa_hd, 0) AS media_dias_exec_tarefa_hd,
        COALESCE(f.qt_tarefas_reclamacao, 0) AS qt_tarefas_reclamacao,
        COALESCE(f.media_dias_exec_reclamacao, 0) AS media_dias_exec_reclamacao,
        COALESCE(f.qt_tarefas_reducao, 0) AS qt_tarefas_reducao,
        COALESCE(f.media_dias_exec_reducao, 0) AS media_dias_exec_reducao,
        COALESCE(f.qt_tarefas_bug, 0) AS qt_tarefas_bug,
        COALESCE(f.media_dias_exec_bug, 0) AS media_dias_exec_bug,
        CASE 
            WHEN c.churn = 1 THEN GREATEST(0, DATEDIFF(c.data_ultimo_cancelamento, COALESCE(f.data_ultima_tarefa_real, c.primeira_assinatura)))
            ELSE DATEDIFF(CURDATE(), COALESCE(f.data_ultima_tarefa_real, c.primeira_assinatura))
        END AS dias_ultima_tarefa,
        COALESCE(f.qtd_categorias_distintas, 0) AS qtd_categorias_distintas,
        COALESCE(f.qtd_subcategorias_distintas, 0) AS qtd_subcategorias_distintas,
        COALESCE(f.qtd_grupos_envolvidos, 0) AS qtd_grupos_envolvidos,
        COALESCE(f.qtd_prioridade_normal, 0) AS qtd_prioridade_normal,
        COALESCE(f.qtd_prioridade_parcial, 0) AS qtd_prioridade_parcial,
        COALESCE(f.qtd_prioridade_urgente, 0) AS qtd_prioridade_urgente,
        COALESCE(f.qtd_prioridade_maxima, 0) AS qtd_prioridade_maxima,
        COALESCE(f.qtd_prioridade_reforco, 0) AS qtd_prioridade_reforco,
        COALESCE(f.perc_prioridade_maxima * 100, 0) AS perc_prioridade_maxima,
        COALESCE(f.meses_de_casa, 0) AS meses_de_casa,
        c.churn
    FROM tb_clientes c
    LEFT JOIN tb_features f ON c.cod_cliente = f.cod_cliente;
    """ 

def executar_pipeline_producao():
    logging.info(f"\n{'*' * 40}\nIniciando rotina diária de probabilidade de Churn...")
    
    # Carregamento de Artefatos com Caminhos Absolutos
    try:
        model  = joblib.load(CAMINHO_MODELO_PKL)
        scaler = joblib.load(CAMINHO_SCALER_PKL)
        with open(CAMINHO_FEATURES_JSON, 'r', encoding='utf-8') as f:
            features_obrigatorias = json.load(f)
        logging.info("Artefatos do modelo carregados com sucesso.")
    except Exception as e:
        logging.error(f"Erro ao carregar arquivos do modelo: {str(e)}")
        return

    # Extração Isolada do Banco
    try:
        engine = obter_engine_banco()
        with engine.connect() as conexao:
            logging.info("Conectando e extraindo clientes ativos...")
            df_banco = pd.read_sql(QUERY_CLIENTES_ATIVOS, conexao)
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
            'risco_churn_percentual':   probabilidades * 100,
            
            # Contexto Financeiro e Contratual (essencial para o CS priorizar por receita!)
            'valor_mensal_ativo':   df_banco['valor_ativo_total'],
            'qtd_contratos_ativos': df_banco['qtd_contratos_ativos'].astype(int),
            'ja_sofreu_downgrade':  df_banco['flg_ja_sofreu_downgrade'].astype(int),
            
            # Comportamento e Engajamento Recente vs Histórico
            # 'meses_de_casa':                X_producao['meses_de_casa'],
            'dias_sem_abrir_chamado':       X_producao['dias_ultima_tarefa'].astype(int),
            'chamados_ultimos_90_dias':     df_banco['tarefas_90d'].astype(int),
            'total_chamados_historico':     df_banco['qtd_tarefas_total'].astype(int),
            'media_dias_resolucao_chamado': df_banco['media_dias_exec'],
            
            # Alertas Críticos de Atrito
            'qt_chamados_bug':                  X_producao['qt_tarefas_bug'].astype(int),
            'qt_chamados_reclamacao':           X_producao['qt_tarefas_reclamacao'].astype(int),
            'media_dias_resolucao_reclamacao':  df_banco['media_dias_exec_reclamacao']
        })
        
        # 2. Arredondamentos sênior do Pandas para o Excel ficar limpo
        df_final['risco_churn_percentual']          = df_final['risco_churn_percentual'].round(2)
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