WITH tb_clientes AS (
    -- Base de clientes no grão correto (1 linha por cliente)
    SELECT
        cct.codigo AS cod_cliente,
        MIN(DATE(cct.assinatura)) AS primeira_assinatura,
        
        -- Guardamos a data do último cancelamento para congelar o tempo do churn
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

        -- ==========================================
        -- VALORES FINANCEIROS POR STATUS (PIVOT)
        -- ==========================================
        SUM(CASE WHEN cct.status = 3 THEN cct.valor_contrato ELSE 0 END) AS valor_ativo_total,
        SUM(CASE WHEN cct.status = 4 THEN cct.valor_contrato ELSE 0 END) AS valor_cancelado_total,

        -- ==========================================
        -- VOLUMETRIA DE CONTRATOS
        -- ==========================================
        SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) AS qtd_contratos_ativos,
        SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) AS qtd_contratos_cancelados,

        -- ==========================================
        -- COMPORTAMENTO DE RECORRÊNCIA (FEATURES)
        -- ==========================================
        CASE 
            WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) > 0 
                 AND SUM(CASE WHEN cct.status = 4 THEN 1 ELSE 0 END) > 0 
            THEN 1 ELSE 0 
        END AS flg_ja_sofreu_downgrade,

        -- ==========================================
        -- TARGET (y) - CHURN REAL
        -- ==========================================
        CASE 
            WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) = 0 THEN 1
            ELSE 0
        END AS churn

    FROM gecobi2.consolida_contratos cct
    WHERE cct.assinatura IS NOT NULL
      AND cct.status IN (3, 4)
--       AND cct.codigo = 21598
    GROUP BY cct.codigo
),

tb_tarefas AS (
    -- Base de tarefas (nível transacional)
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
	    WHEN utb.grupo_trabalho IN (3, 29, 64) AND sto.sto IN ('X', 'V') -- Finalizadas
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL -- NULL garante que o AVG ignore as tarefas de outros grupos
	END AS dias_exec_tarefa_sd,

	CASE
	    WHEN utb.grupo_trabalho IN (5, 23, 63) AND sto.sto IN ('X', 'V')
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_hd,

	CASE
	    WHEN otb.categoria IN (304) AND sto.sto IN ('X', 'V')
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_reclamacao,

	CASE
	    WHEN otb.categoria IN (18402, 18441, 18468) AND sto.sto IN ('X', 'V')
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_reducao,

	CASE
		WHEN (
				LOWER(stv1.dst) LIKE '%bug%' OR LOWER(stv2.dst) LIKE '%bug%'
			) AND sto.sto IN ('X', 'V')
			THEN DATEDIFF(otb.data_exe, otb.data_cad)
	    ELSE NULL
	END AS dias_exec_tarefa_bug,
	
	utb.grupo_trabalho

    FROM gecobi2.ordemser_tb otb

    LEFT JOIN gecobi2.stos_tb sto
        ON otb.stos = sto.cod

    LEFT JOIN gecobi2.usu_tb utb
        ON otb.para1 = utb.cod_usu
    
    LEFT JOIN gecobi2.stven_tb stv1
        ON otb.categoria = stv1.st
    
    LEFT JOIN gecobi2.stven_tb stv2
        ON otb.subcategoria = stv2.st

    WHERE otb.nros_sub = 0 
        AND otb.stos NOT IN ('CAN', 'PGE') -- Tarefas Canceladas ou de Faturamento
        AND LOWER(COALESCE(stv1.dst, '')) NOT LIKE '%cancel%' -- Categoria de Cancelamento de MRR
        AND LOWER(COALESCE(stv2.dst, '')) NOT LIKE '%cancel%' -- Subcategoria de Cancelamento de MRR
		AND otb.categoria NOT IN (210,   -- INSTALAÇÃO
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

        -- volume de interações
        COUNT(*) AS qtd_tarefas_total,

        -- Guardamos apenas a data máxima do cadastro da tarefa para calcular o DATEDIFF no bloco final
        MAX(t.data_cad) AS data_ultima_tarefa_real,

        -- atividade recente
        SUM(
            CASE 
                WHEN t.data_cad >= CURDATE() - INTERVAL 90 DAY 
                THEN 1 ELSE 0 
            END
        ) AS tarefas_90d,

        -- eficiência operacional
        AVG(t.dias_exec_tarefa) 			AS media_dias_exec,
		AVG(t.dias_exec_tarefa_sd) 			AS media_dias_exec_tarefa_sd,
		AVG(t.dias_exec_tarefa_hd) 			AS media_dias_exec_tarefa_hd,
		AVG(t.dias_exec_tarefa_reclamacao) 	AS media_dias_exec_reclamacao,
		AVG(t.dias_exec_tarefa_reducao) 	AS media_dias_exec_reducao,
		AVG(t.dias_exec_tarefa_bug) 		AS media_dias_exec_bug,
		
        -- backlog (tarefas abertas)
--         SUM(CASE WHEN t.tarefa_finalizada = 0 THEN 1 ELSE 0 END) AS qtd_tarefas_abertas,

        -- diversidade de uso
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

        -- PRIORIDADES
        SUM(CASE WHEN t.prioridade IN (0,1) THEN 1 ELSE 0 END)  AS qtd_prioridade_normal,
        SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END)       AS qtd_prioridade_parcial,
        SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END)       AS qtd_prioridade_urgente,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END)       AS qtd_prioridade_maxima,
        SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END)       AS qtd_prioridade_reforco,

        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) / COUNT(*) AS perc_prioridade_maxima

    FROM tb_tarefas t
    GROUP BY t.cod_cliente
)

-- =========================
-- DATASET FINAL (X + y)
-- =========================
SELECT
    c.cod_cliente,
    c.primeira_assinatura,

    -- FEATURES FINANCEIRAS / CONTRATO
    c.valor_ativo_total,
    c.valor_cancelado_total,
    c.qtd_contratos_ativos,
    c.qtd_contratos_cancelados,
    c.flg_ja_sofreu_downgrade,

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
--     COALESCE(f.perc_tarefas_abertas * 100, 0)   AS perc_tarefas_abertas,

    -- TARGET (y)
    c.churn

FROM tb_clientes c

LEFT JOIN tb_features f
    ON c.cod_cliente = f.cod_cliente;