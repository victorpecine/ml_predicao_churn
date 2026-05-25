-- ==============================================================================
-- PIPELINE DE PRODUÇÃO: EXTRAÇÃO DE MATRIZ DE RECURSOS (FEATURES X) PARA CHURN
-- MÓDULO: SELEÇÃO DE CLIENTES ATIVOS E COMPORTAMENTO OPERACIONAL
-- SISTEMA: PREÂMBULO INFORMÁTICA LTDA
-- ==============================================================================

WITH tb_clientes AS (
    -- Base de clientes ativos (Garante estritamente 1 linha por código de cliente)
    SELECT
        cct.codigo AS cod_cliente,
        MIN(DATE(cct.assinatura)) AS primeira_assinatura,

        -- Agregação para o cálculo interno do Score de Atrito (Retido internamente, sem vazar para o SELECT final)
        SUM(CASE WHEN cct.status = 3 THEN cct.valor_contrato ELSE 0 END) AS valor_ativo_total,

        -- COMPORTAMENTO DE RECORRÊNCIA CONTRATUAL (Geração de Feature)       
        CASE 
            WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) > 0 
                 AND SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) > 0 
            THEN 1 ELSE 0 
        END AS flag_ja_sofreu_downgrade

    FROM gecobi2.consolida_contratos cct
    WHERE cct.assinatura IS NOT NULL
      AND cct.status IN (3, 4) -- Varre o histórico estrito de contratos ativos e cancelados
    GROUP BY cct.codigo
    HAVING SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) > 0 -- REQUISITO DE PROD: Filtra apenas clientes com contratos ativos hoje
),

tb_tarefas AS (
    -- Base de tarefas com classificação de atrito, eficiência e travas de integridade temporal
    SELECT
        otb.cliente AS cod_cliente,
        otb.data_cad,
        otb.data_exe,
        otb.categoria,
        stv1.dst AS descr_categoria,
        otb.subcategoria,
        stv2.dst AS descr_subcategoria,
        otb.prioridade,
        utb.grupo_trabalho,
        
        -- Identificação de Status de Abertura atual da tarefa
        CASE WHEN sto.sto NOT IN ('X', 'V') THEN 1 ELSE 0 END AS flag_aberta,

        -- BLINDAGEM DE OUTLIERS: DATEDIFF geral condicionado a datas fisicamente válidas
        CASE 
            WHEN otb.data_exe >= otb.data_cad THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL 
        END AS dias_exec_tarefa,

        -- Mapeamento das eficiências por canais específicos (Apenas tarefas devidamente finalizadas 'X' ou 'V')
        CASE
            WHEN utb.grupo_trabalho IN (3, 29, 64) AND sto.sto IN ('X', 'V') AND otb.data_exe >= otb.data_cad 
            THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_sd,

        CASE
            WHEN utb.grupo_trabalho IN (5, 23, 63) AND sto.sto IN ('X', 'V') AND otb.data_exe >= otb.data_cad 
            THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_hd,

        CASE
            WHEN otb.categoria IN (304) AND sto.sto IN ('X', 'V') AND otb.data_exe >= otb.data_cad 
            THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_reclamacao,

        CASE
            WHEN otb.categoria IN (18402, 18441, 18468) AND sto.sto IN ('X', 'V') AND otb.data_exe >= otb.data_cad 
            THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_reducao,

        CASE
            WHEN (LOWER(stv1.dst) LIKE '%bug%' OR LOWER(stv2.dst) LIKE '%bug%') AND sto.sto IN ('X', 'V') AND otb.data_exe >= otb.data_cad 
            THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_bug

    FROM         gecobi2.ordemser_tb otb
    LEFT JOIN    gecobi2.stos_tb      sto  ON otb.stos         = sto.cod
    LEFT JOIN    gecobi2.usu_tb       utb  ON otb.para1        = utb.cod_usu
    LEFT JOIN    gecobi2.stven_tb     stv1 ON otb.categoria    = stv1.st
    LEFT JOIN    gecobi2.stven_tb     stv2 ON otb.subcategoria = stv2.st

    WHERE otb.nros_sub = 0 -- Restringe estritamente a tarefas principais (ignora subtarefas para evitar dupla contagem)
        AND otb.stos NOT IN ('CAN', 'PGE') -- Filtra fora tarefas Canceladas ou de Faturamento Interno
        AND LOWER(COALESCE(stv1.dst, '')) NOT LIKE '%cancel%' -- Exclui fluxos de cancelamento de MRR (evita vazamento de target)
        AND LOWER(COALESCE(stv2.dst, '')) NOT LIKE '%cancel%' 
        AND sto.descr NOT LIKE '%RETORNO%'
        AND otb.categoria NOT IN ( -- Filtro estrito: Remoção de categorias sem impacto causal direto no churn
            210,   -- INSTALAÇÃO
            224,   -- TREINAMENTO / ATENDIMENTO PRESENCIAL
            225,   -- TREINAMENTO / ATENDIMENTO REMOTO
            352,   -- CONTRATO - RENOVAÇÃO CONTRATUAL
            367,   -- DUVIDAS CONTRATUAIS
            16375, -- PREÂMBULO ACADEMY
            15693, -- TREINAMENTO CRM
            17367, -- MELHORIAS 3C
            17536, -- SUGESTÃO DE MELHORIA
            18327, -- CONTRATO OFFICE
            21486  -- VENDAS COMERCIAL
        )
),

tb_features AS (
    -- Agregação estatística e consolidação do estoque de fricção por cliente
    SELECT
        t.cod_cliente,
        COUNT(*) AS qt_tarefas_total,
        MAX(t.data_cad) AS data_ultima_tarefa_real,

        -- Médias operacionais de tempo de resolução (Protegidas contra nulos e distorções)
        AVG(t.dias_exec_tarefa)             AS media_dias_exec,
        AVG(t.dias_exec_tarefa_sd)          AS media_dias_exec_tarefa_sd,
        AVG(t.dias_exec_tarefa_hd)          AS media_dias_exec_tarefa_hd,
        AVG(t.dias_exec_tarefa_reclamacao)  AS media_dias_exec_reclamacao,
        AVG(t.dias_exec_tarefa_reducao)     AS media_dias_exec_reducao,
        AVG(t.dias_exec_tarefa_bug)         AS media_dias_exec_bug,

        -- Diversidade volumétrica de canais e escopo
        COUNT(DISTINCT t.categoria)         AS qt_categorias_distintas,
        COUNT(DISTINCT t.subcategoria)      AS qt_subcategorias_distintas,
        COUNT(DISTINCT t.grupo_trabalho)    AS qt_grupos_envolvidos,
        
        -- Volumetria acumulada por segmentação de atendimento
        SUM(CASE WHEN t.grupo_trabalho IN (3, 29, 64) THEN 1 ELSE 0 END) AS qt_tarefas_sd,
        SUM(CASE WHEN t.grupo_trabalho IN (5, 23, 63) THEN 1 ELSE 0 END) AS qt_tarefas_hd,
        SUM(CASE WHEN t.categoria IN (304) THEN 1 ELSE 0 END)            AS qt_tarefas_reclamacao,
        SUM(CASE WHEN t.categoria IN (18402, 18441, 18468) THEN 1 ELSE 0 END) AS qt_tarefas_reducao,
        SUM(CASE WHEN LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%' THEN 1 ELSE 0 END) AS qt_tarefas_bug,

        -- Monitoramento crítico do estoque de passivos em aberto (Sinalizadores de Atrito Atuais)
        SUM(CASE WHEN t.flag_aberta = 1 THEN 1 ELSE 0 END) AS qt_tarefas_abertas_atual,
        SUM(CASE WHEN t.flag_aberta = 1 AND (LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%') THEN 1 ELSE 0 END) AS qt_bugs_abertos_atual,
        SUM(CASE WHEN t.flag_aberta = 1 AND t.categoria IN (304) THEN 1 ELSE 0 END) AS qt_reclamacoes_abertas_atual,
        SUM(CASE WHEN t.flag_aberta = 1 AND t.categoria IN (18402, 18441, 18468) THEN 1 ELSE 0 END) AS qt_reducoes_abertas_atual,

        -- Distribuição de severidade e nível de criticidade
        SUM(CASE WHEN t.prioridade IN (0, 1) THEN 1 ELSE 0 END) AS qt_prioridade_normal,
        SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END)       AS qt_prioridade_parcial,
        SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END)       AS qt_prioridade_urgente,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END)       AS qt_prioridade_maxima,
        SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END)       AS qt_prioridade_reforco,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) / COUNT(*) AS perc_prioridade_maxima

    FROM tb_tarefas t
    GROUP BY t.cod_cliente
)

-- DATASET FINAL DE PRODUÇÃO (Alinhamento exato com as colunas esperadas pelo RobustScaler)
SELECT
    c.cod_cliente,
    c.primeira_assinatura,

    -- Recursos Contratuais
    c.flag_ja_sofreu_downgrade,

    -- Recursos de Performance Operacional e Volumetria
    COALESCE(f.qt_tarefas_total, 0)             AS qt_tarefas_total,
    COALESCE(f.media_dias_exec, 0)              AS media_dias_exec,
    
    COALESCE(f.qt_tarefas_sd, 0)                AS qt_tarefas_sd,
    COALESCE(f.media_dias_exec_tarefa_sd, 0)    AS media_dias_exec_tarefa_sd,
    
    COALESCE(f.qt_tarefas_hd, 0)                AS qt_tarefas_hd,
    COALESCE(f.media_dias_exec_tarefa_hd, 0)    AS media_dias_exec_tarefa_hd,
    
    COALESCE(f.qt_tarefas_reclamacao, 0)        AS qt_tarefas_reclamacao,
    COALESCE(f.media_dias_exec_reclamacao, 0)   AS media_dias_exec_reclamacao,
    
    COALESCE(f.qt_tarefas_reducao, 0)           AS qt_tarefas_reducao,
    COALESCE(f.media_dias_exec_reducao, 0)      AS media_dias_exec_reducao,
    
    COALESCE(f.qt_tarefas_bug, 0)               AS qt_tarefas_bug,
    COALESCE(f.media_dias_exec_bug, 0)          AS media_dias_exec_bug,

    -- Recursos de Estoque de Pendências Acumuladas
    COALESCE(f.qt_tarefas_abertas_atual, 0)     AS qt_tarefas_abertas_atual,
    COALESCE(f.qt_bugs_abertos_atual, 0)        AS qt_bugs_abertos_atual,
    COALESCE(f.qt_reclamacoes_abertas_atual, 0) AS qt_reclamacoes_abertas_atual,
    COALESCE(f.qt_reducoes_abertas_atual, 0)    AS qt_reducoes_abertas_atual,
    
    -- Recência Operacional Calculada Dinamicamente contra a data de execução atual (CURDATE)
    DATEDIFF(CURDATE(), COALESCE(f.data_ultima_tarefa_real, c.primeira_assinatura)) AS dias_ultima_tarefa,
    
    -- Complexidade de Uso e Segmentação de Atendimento
    COALESCE(f.qt_categorias_distintas,     0)  AS qt_categorias_distintas,
    COALESCE(f.qt_subcategorias_distintas,  0)  AS qt_subcategorias_distintas,
    COALESCE(f.qt_grupos_envolvidos,        0)  AS qt_grupos_envolvidos,

    -- Métricas Distribucionais de Prioridades
    COALESCE(f.qt_prioridade_normal,  0)        AS qt_prioridade_normal,
    COALESCE(f.qt_prioridade_parcial, 0)        AS qt_prioridade_parcial,
    COALESCE(f.qt_prioridade_urgente, 0)        AS qt_prioridade_urgente,
    COALESCE(f.qt_prioridade_maxima,  0)        AS qt_prioridade_maxima,
    COALESCE(f.qt_prioridade_reforco, 0)        AS qt_prioridade_reforco,
    COALESCE(f.perc_prioridade_maxima * 100, 0) AS perc_prioridade_maxima,

    -- Tempo de Relacionamento (Mensalizado utilizando o padrão financeiro de 30.44 dias por mês)
    ROUND(DATEDIFF(CURDATE(), c.primeira_assinatura) / 30.44, 1) AS meses_de_casa 

FROM tb_clientes c
LEFT JOIN tb_features f ON c.cod_cliente = f.cod_cliente;