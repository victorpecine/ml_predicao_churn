WITH tb_clientes AS (
    -- Base de clientes (1 linha por cliente)
    SELECT
        cct.codigo AS cod_cliente,
        MIN(DATE(cct.assinatura)) AS primeira_assinatura,
        
        -- Traz a data do último cancelamento para congelar o tempo do churn
        -- Se não houver data de cancelamento considera a data de vencimento do contrato
        MAX(
			CASE
				WHEN cct.status = 4
					THEN DATE(
						COALESCE(cct.cancelamento, cct.vencimento)
						)
					ELSE NULL
				END
			) AS data_ultimo_cancelamento,

        
        -- VALORES FINANCEIROS POR STATUS        
        SUM(CASE WHEN cct.status = 3 THEN cct.valor_contrato ELSE 0 END) AS valor_ativo_total,
        SUM(CASE WHEN cct.status = 4 THEN cct.valor_contrato ELSE 0 END) AS valor_cancelado_total,

        -- VOLUMETRIA DE CONTRATOS        
        SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) AS qtd_contratos_ativos,
        SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) AS qtd_contratos_cancelados,

        -- COMPORTAMENTO DE RECORRÊNCIA (FEATURES)       
        CASE 
            WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) > 0 
                 AND SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) > 0 
            THEN 1 ELSE 0 
        END AS flag_ja_sofreu_downgrade,
        
        -- TARGET (y) - CHURN REAL        
        CASE 
            WHEN
				SUM(
					CASE
						WHEN cct.status = 3
							THEN 1 
						ELSE 0
					END) = 0 THEN 1
            ELSE 0
        END AS churn

    FROM gecobi2.consolida_contratos cct
    WHERE cct.assinatura IS NOT NULL
      AND cct.status IN (3, 4) -- Ativos e Cancelados
--        AND cct.codigo = 21598
    GROUP BY cct.codigo
),

tb_tarefas AS (
    -- Base de tarefas
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

	CASE
	    WHEN utb.grupo_trabalho IN (3, 29, 64) AND sto.sto IN ('X', 'V') -- Service Desk Finalizadas
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL -- NULL garante que o AVG ignore as tarefas de outros grupos
	END AS dias_exec_tarefa_sd,

	CASE
	    WHEN utb.grupo_trabalho IN (5, 23, 63) AND sto.sto IN ('X', 'V') -- Help Desk Finalizadas
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_hd,

	CASE
	    WHEN otb.categoria IN (304) AND sto.sto IN ('X', 'V') -- Reclamações Finalizadas
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_reclamacao,

	CASE
	    WHEN otb.categoria IN (18402, 18441, 18468) AND sto.sto IN ('X', 'V') -- Reduções Finalizadas
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_reducao,

	CASE
		WHEN (
				LOWER(stv1.dst) LIKE '%bug%' OR LOWER(stv2.dst) LIKE '%bug%' -- Bugs Finalizadas
			) AND sto.sto IN ('X', 'V')
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_bug,
	
	utb.grupo_trabalho

    FROM 		gecobi2.ordemser_tb otb
    LEFT JOIN 	gecobi2.stos_tb 	sto 	ON otb.stos 		= sto.cod
    LEFT JOIN 	gecobi2.usu_tb 		utb 	ON otb.para1 		= utb.cod_usu
    LEFT JOIN 	gecobi2.stven_tb 	stv1	ON otb.categoria 	= stv1.st
    LEFT JOIN 	gecobi2.stven_tb 	stv2 	ON otb.subcategoria = stv2.st

    WHERE otb.nros_sub = 0 -- Somente tarefas principais
        AND otb.stos NOT IN ('CAN', 'PGE') -- Tarefas Canceladas ou de Faturamento
        AND LOWER(COALESCE(stv1.dst, '')) NOT LIKE '%cancel%' -- Categoria de Cancelamento de MRR
        AND LOWER(COALESCE(stv2.dst, '')) NOT LIKE '%cancel%' -- Subcategoria de Cancelamento de MRR
		AND otb.categoria NOT IN ( -- Tarefas sem importância para churn
			210,   -- INSTALAÇÃO
			224,   -- TREINAMENTO / ATENDIMENTO PRESENCIAL
			225,   -- TREINAMENTO / ATENDIMENTO REMOTO
			352,   -- CONTRATO -RENOVAÇÃO CONTRATUAL
			367,   -- DUVIDAS CONTRATUAIS
			16375, -- PREÂMBULO ACADEMY
			15693, -- TREINAMENTO CRM
			17367, -- MELHORIAS 3C
			17536, -- SUGESTÃO DE MELHORIA
			18327, -- CONTRATO OFFICE
			21486  -- VENDAS COMERCIAL
			)
		AND sto.descr NOT LIKE '%RETORNO%' -- Tarefas que a continuidade depende do cliente
),

tb_features AS (
    -- Agregação: 1 linha por cliente (features para ML)
    SELECT
        t.cod_cliente,

        -- Volume de interações
        COUNT(*) AS qtd_tarefas_total,

        -- Data máxima do cadastro da tarefa para calcular o DATEDIFF no bloco final
        MAX(t.data_cad) AS data_ultima_tarefa_real,

        -- Eficiência operacional
        AVG(t.dias_exec_tarefa) 			AS media_dias_exec,
		AVG(t.dias_exec_tarefa_sd) 			AS media_dias_exec_tarefa_sd,
		AVG(t.dias_exec_tarefa_hd) 			AS media_dias_exec_tarefa_hd,
		AVG(t.dias_exec_tarefa_reclamacao) 	AS media_dias_exec_reclamacao,
		AVG(t.dias_exec_tarefa_reducao) 	AS media_dias_exec_reducao,
		AVG(t.dias_exec_tarefa_bug) 		AS media_dias_exec_bug,

        -- Diversidade de uso
        COUNT(DISTINCT t.categoria)         AS qtd_categorias_distintas,
        COUNT(DISTINCT t.subcategoria)      AS qtd_subcategorias_distintas,
        COUNT(DISTINCT t.grupo_trabalho)	AS qtd_grupos_envolvidos,
        
        SUM(
			CASE
				WHEN t.grupo_trabalho IN (3,29, 64) -- Service Desk
					THEN 1
				ELSE 0
			END) AS qt_tarefas_sd,
        
        SUM(
			CASE
				WHEN t.grupo_trabalho IN (5, 23, 63) -- Help Desk
					THEN 1
				ELSE 0
			END) AS qt_tarefas_hd,
        
        SUM(
			CASE
				WHEN t.categoria IN (304)
					THEN 1
				ELSE 0
			END) AS qt_tarefas_reclamacao,
        
        SUM(
			CASE
				WHEN t.categoria IN (18402, 18441, 18468)
					THEN 1
				ELSE 0
			END) AS qt_tarefas_reducao,
			
        SUM(
			CASE
				WHEN 
					LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%'
					THEN 1
				ELSE 0
			END) AS qt_tarefas_bug,

        -- Quantidade de tarefas abertas nos últimos 90 dias
        SUM(
            CASE 
                WHEN t.data_cad >= CURDATE() - INTERVAL 90 DAY 
                THEN 1 ELSE 0 
            END
        ) AS tarefas_90d,
			
		SUM(
			CASE
				WHEN t.data_cad >= CURDATE() - INTERVAL 90 DAY
					 AND t.categoria IN (304)
					THEN 1
				ELSE 0
			END) AS qt_reclamacoes_90d,

		SUM(
			CASE
				WHEN t.data_cad >= CURDATE() - INTERVAL 90 DAY
					 AND (LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%')
					THEN 1
				ELSE 0
			END) AS qt_bugs_90d,

        -- Prioridade das tarefas
        SUM(CASE WHEN t.prioridade IN (0,1) THEN 1 ELSE 0 END)  AS qtd_prioridade_normal,
        SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END)       AS qtd_prioridade_parcial,
        SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END)       AS qtd_prioridade_urgente,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END)       AS qtd_prioridade_maxima,
        SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END)       AS qtd_prioridade_reforco,

        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) / COUNT(*) AS perc_prioridade_maxima

    FROM tb_tarefas t
    GROUP BY t.cod_cliente
)

-- DATASET FINAL (X + y)
SELECT
    c.cod_cliente,
    c.primeira_assinatura,

    -- FEATURES FINANCEIRAS / CONTRATO
    c.valor_ativo_total,
    c.valor_cancelado_total,
    c.qtd_contratos_ativos,
    c.qtd_contratos_cancelados,
    c.flag_ja_sofreu_downgrade,

    -- FEATURES OPERACIONAIS
    COALESCE(f.tarefas_90d, 0)                  AS tarefas_90d,
    
    COALESCE(f.qtd_tarefas_total, 0) 			AS qtd_tarefas_total,
    COALESCE(f.media_dias_exec, 0)              AS media_dias_exec,
    
    COALESCE(f.qt_tarefas_sd, 0)        		AS qt_tarefas_sd,
    COALESCE(f.media_dias_exec_tarefa_sd, 0)	AS media_dias_exec_tarefa_sd,
    
    COALESCE(f.qt_tarefas_hd, 0)        		AS qt_tarefas_hd,
    COALESCE(f.media_dias_exec_tarefa_hd, 0)	AS media_dias_exec_tarefa_hd,
    
    COALESCE(f.qt_tarefas_reclamacao, 0)        AS qt_tarefas_reclamacao,
    COALESCE(f.media_dias_exec_reclamacao, 0) 	AS media_dias_exec_reclamacao,
    
    COALESCE(f.qt_tarefas_reducao, 0)           AS qt_tarefas_reducao,
    COALESCE(f.media_dias_exec_reducao, 0) 		AS media_dias_exec_reducao,
    
	COALESCE(f.qt_tarefas_bug, 0)               AS qt_tarefas_bug,
	COALESCE(f.media_dias_exec_bug, 0) 			AS media_dias_exec_bug,
    
    -- PROTEÇÃO CONTRA NEGATIVOS: Se der menor que 0, vira 0 (Uso máximo até o cancelamento)	
	CASE 
        WHEN c.churn = 1 THEN 
            -- Se nunca abriu tarefa, a recência assume o tempo total de casa (Data Cancelamento - Assinatura)
            GREATEST(0, DATEDIFF(c.data_ultimo_cancelamento, COALESCE(f.data_ultima_tarefa_real, c.primeira_assinatura)))
        ELSE 
            -- Se ativo e sem tarefas, a recência vira o tempo de isolamento desde que entrou (Hoje - Assinatura)
            DATEDIFF(CURDATE(), COALESCE(f.data_ultima_tarefa_real, c.primeira_assinatura))
    END AS dias_ultima_tarefa,
    
    COALESCE(f.qtd_categorias_distintas, 0)     AS qtd_categorias_distintas,
    COALESCE(f.qtd_subcategorias_distintas, 0)  AS qtd_subcategorias_distintas,
    COALESCE(f.qtd_grupos_envolvidos, 0)        AS qtd_grupos_envolvidos,

    COALESCE(f.qtd_prioridade_normal, 0)        AS qtd_prioridade_normal,
    COALESCE(f.qtd_prioridade_parcial, 0)       AS qtd_prioridade_parcial,
    COALESCE(f.qtd_prioridade_urgente, 0)       AS qtd_prioridade_urgente,
    COALESCE(f.qtd_prioridade_maxima, 0)        AS qtd_prioridade_maxima,
    COALESCE(f.qtd_prioridade_reforco, 0)       AS qtd_prioridade_reforco,

    COALESCE(f.perc_prioridade_maxima * 100, 0) AS perc_prioridade_maxima,
	
	-- SAÚDE & ATRITO TÉCNICO	
	-- 1. PROPORÇÃO DE ATRITO CRÍTICO RECENTE
	-- Mede a porcentagem das tarefas dos últimos 90 dias que foram motivadas por Bugs ou Reclamações.
	-- Evita a divisão por zero caso o cliente esteja em silêncio absoluto na janela de 90 dias.
	CASE
		WHEN COALESCE(f.tarefas_90d, 0) > 0
			THEN ROUND((COALESCE(f.qt_bugs_90d, 0) + COALESCE(f.qt_reclamacoes_90d, 0)) / f.tarefas_90d * 100, 2)
		ELSE 0
	END AS prop_atrito_recentes_percentual,

	-- 2. ÍNDICE DE TENDÊNCIA DE CHAMADOS (ANOMALIA DE VOLUME)
	-- Compara o volume diário dos últimos 90 dias com a média diária histórica de todo o ciclo de vida do cliente.
	-- Resultado = 1.0 (Normalidade): O cliente está abrindo chamados exatamente no mesmo ritmo de sempre. A operação dele está estável.
	-- Resultado Próximo de 0 (Silenciamento): Significa que o volume dos últimos 90 dias caiu drasticamente se comparado ao passado. O cliente está parando de usar o suporte (Alerta de Churn Silencioso!).
	-- Resultado Superior a 2.0 ou 3.0 (Anomalia/Crise): Significa que o cliente está abrindo 2 a 3 vezes mais chamados por dia agora do que a média histórica dele.
	CASE
		WHEN (COALESCE(f.qtd_tarefas_total, 0) - COALESCE(f.tarefas_90d, 0)) > 0 -- Volume de chamados que ele abriu na vida, tirando os últimos 3 meses
			 THEN ROUND(
				(COALESCE(f.tarefas_90d, 0) / 90) / -- Frequência diária atual do cliente
				( -- Comportamento histórico de base do cliente
					(COALESCE(f.qtd_tarefas_total, 0) - COALESCE(f.tarefas_90d, 0)) /
						-- GREATEST(1, ...) é uma blindagem para o caso de um cliente ter entrado hoje
				 		GREATEST(1, DATEDIFF(CURDATE(), c.primeira_assinatura))), 2
			 )
		ELSE 1
	END AS index_tendencia_volume_recentes,

	-- 3. EFICIÊNCIA DE ATENDIMENTO VS TAMANHO DO CLIENTE
	-- Multiplica o tempo médio de resolução de reclamações pelo faturamento mensal ativo.
	-- O objetivo é penalizar severamente a lentidão no suporte para contas de alto MRR (Alto valor com alto SLA estourado = Risco Crítico).
	ROUND(
		COALESCE(f.media_dias_exec_reclamacao, 0) * COALESCE(c.valor_ativo_total, 0),
		2) AS score_atrito_sla_financeiro,

    -- TARGET (y)
    c.churn

FROM tb_clientes c

LEFT JOIN tb_features f
    ON c.cod_cliente = f.cod_cliente;