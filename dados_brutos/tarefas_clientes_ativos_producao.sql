WITH tb_clientes AS (
-- Base de clientes (1 linha por cliente)
	SELECT
	    cct.codigo AS cod_cliente,
	
	    MIN(DATE(cct.assinatura)) AS primeira_assinatura,
	    
	    -- Se não houver data de cancelamento considera a data de vencimento do contrato
	    MAX(
	        CASE
	            WHEN cct.status = 4 THEN
	                CASE
	                    WHEN cct.cancelamento < cct.assinatura
	                        OR cct.cancelamento IS NULL
	                    THEN cct.vencimento
	                    ELSE cct.cancelamento
	                END
	            ELSE null
	        END
	            ) AS data_cancelamento,
	        
	        CAST(
	            SUM(cci.valor_total) AS DECIMAL(10, 2)
	         ) AS valor_contrato,
	    
	    -- Target y
	    CASE 
	        WHEN SUM(CASE WHEN cct.status = 3 THEN 1 ELSE 0 END) = 0 THEN 1
	        ELSE 0
	    END AS churn
	
	FROM        gecobi2.consolida_contratos cct
	LEFT JOIN (
	    SELECT 
	        id_contrato,
	        SUM(quantidade * valor) AS valor_total
	    FROM cliwcs.cad_contrato_itens
	    GROUP BY id_contrato
	) cci ON cct.idcontrato = cci.id_contrato
	
	WHERE cct.assinatura IS NOT NULL
	  AND cct.status IN (3, 4) -- Ativos e Cancelados
-- 	  AND cct.codigo = 45158
	GROUP BY cct.codigo

),

tb_conslida_tarefas AS (
	SELECT
	    otb.cliente AS cod_cliente,
	
	    TIMESTAMPDIFF(
	                DAY,
	                otb.data_cad,
	                COALESCE(
	                    NULLIF(otb.data_exe, '0000-00-00'), hit.data_exe_hist)
					) AS dias_exec_tarefa,
	    
	    otb.categoria,
	    stv1.dst AS descr_categoria,
	    otb.subcategoria,
	    stv2.dst AS descr_subcategoria,
	    otb.prioridade,
	    utb.grupo_trabalho,
	
	    -- Mapeamento das eficiências de tarefas já finalizadas (Para cálculo de médias históricas)
	    CASE
	        WHEN utb.grupo_trabalho IN (3, 29, 64) AND otb.data_exe IS NOT NULL
	            THEN TIMESTAMPDIFF(DAY, otb.data_cad, otb.data_exe)
	        ELSE NULL
	    END AS dias_exec_tarefa_sd,
	
	    CASE
	        WHEN utb.grupo_trabalho IN (5, 23, 63) AND otb.data_exe IS NOT NULL
	            THEN TIMESTAMPDIFF(DAY, otb.data_cad, otb.data_exe)
	        ELSE NULL
	    END AS dias_exec_tarefa_hd,
	
	    CASE
	        WHEN otb.categoria IN (304) AND otb.data_exe IS NOT NULL
	            THEN TIMESTAMPDIFF(DAY, otb.data_cad, otb.data_exe)
	        ELSE NULL
	    END AS dias_exec_tarefa_reclamacao,
	
	    CASE
	        WHEN otb.categoria IN (18402, 18441, 18468) AND otb.data_exe IS NOT NULL
	            THEN TIMESTAMPDIFF(DAY, otb.data_cad, otb.data_exe)
	        ELSE NULL
	    END AS dias_exec_tarefa_reducao,
	
	    CASE
	        WHEN (LOWER(stv1.dst) LIKE '%bug%' OR LOWER(stv2.dst) LIKE '%bug%') AND otb.data_exe IS NOT NULL
	            THEN TIMESTAMPDIFF(DAY, otb.data_cad, otb.data_exe)
	        ELSE NULL
	    END AS dias_exec_tarefa_bug
	
	FROM        tb_clientes            tbc
	LEFT JOIN   gecobi2.ordemser_tb otb       ON tbc.cod_cliente = otb.cliente
	LEFT JOIN   gecobi2.stos_tb     sto       ON otb.stos         = sto.cod
	LEFT JOIN   gecobi2.usu_tb      utb       ON otb.para1        = utb.cod_usu
	LEFT JOIN   gecobi2.stven_tb    stv1      ON otb.categoria    = stv1.st
	LEFT JOIN   gecobi2.stven_tb    stv2      ON otb.subcategoria = stv2.st
	LEFT JOIN   gecobi2.produtos_tb ptb       ON otb.cod_ps       = ptb.cod_ps
	LEFT JOIN (
	    SELECT
	        nros,
	        MAX(datafos) AS data_exe_hist
	    FROM gecobi2.hist_os_tb
	    GROUP BY nros
	    ) hit ON otb.nros = hit.nros
	
	
	WHERE otb.nros_sub = 0 -- Somente tarefas principais
	--      AND sto.sto IN ('X', 'V') -- Tarefas finalizadas
		AND otb.stos NOT IN ('CAN', 'PGE') -- Tarefas Canceladas ou de Faturamento
		AND LOWER(COALESCE(stv1.dst, '')) NOT LIKE '%cancel%' -- Categoria de Cancelamento de MRR
		AND LOWER(COALESCE(stv2.dst, '')) NOT LIKE '%cancel%' -- Subcategoria de Cancelamento de MRR
-- 		AND otb.categoria NOT IN ( -- Tarefas sem importância para churn
-- 		210,   -- INSTALAÇÃO
-- 		224,   -- TREINAMENTO / ATENDIMENTO PRESENCIAL
-- 		225,   -- TREINAMENTO / ATENDIMENTO REMOTO
-- 		352,   -- CONTRATO -RENOVAÇÃO CONTRATUAL
-- 		367,   -- DUVIDAS CONTRATUAIS
-- 		16375, -- PREÂMBULO ACADEMY
-- 		15693, -- TREINAMENTO CRM
-- 		17367, -- MELHORIAS 3C
-- 		17536, -- SUGESTÃO DE MELHORIA
-- 		18327, -- CONTRATO OFFICE
-- 		21486  -- VENDAS COMERCIAL
-- 	)
),

tb_features AS (
	-- Agregação e inteligência de estoque de dor por tipo de cliente
	SELECT
	    t.cod_cliente,
	
	    COUNT(*) AS qt_tarefas_total,
	    
	    -- Médias operacionais de resolução histórica
	    AVG(t.dias_exec_tarefa)             AS media_dias_exec,
	    AVG(t.dias_exec_tarefa_sd)          AS media_dias_exec_tarefa_sd,
	    AVG(t.dias_exec_tarefa_hd)          AS media_dias_exec_tarefa_hd,
	    AVG(t.dias_exec_tarefa_reclamacao)  AS media_dias_exec_reclamacao,
	    AVG(t.dias_exec_tarefa_reducao)     AS media_dias_exec_reducao,
	    AVG(t.dias_exec_tarefa_bug)         AS media_dias_exec_bug,
	
	    -- Diversidade de interações
	    COUNT(DISTINCT t.categoria)         AS qt_categorias_distintas,
	    COUNT(DISTINCT t.subcategoria)      AS qt_subcategorias_distintas,
	    COUNT(DISTINCT t.grupo_trabalho)    AS qt_grupos_envolvidos,
	    
	    -- VOLUMETRIA ESPECÍFICA
	    SUM(CASE WHEN t.grupo_trabalho IN (3, 29, 64) THEN 1 ELSE 0 END)         AS qt_tarefas_sd,
	    SUM(CASE WHEN t.grupo_trabalho IN (5, 23, 63) THEN 1 ELSE 0 END)         AS qt_tarefas_hd,
	    SUM(CASE WHEN t.categoria IN (304) THEN 1 ELSE 0 END)                    AS qt_tarefas_reclamacao,
	    SUM(CASE WHEN t.categoria IN (18402, 18441, 18468) THEN 1 ELSE 0 END)    AS qt_tarefas_reducao,
	    SUM(CASE WHEN LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%' THEN 1 ELSE 0 END) AS qt_tarefas_bug,
	
	    -- Severidade de prioridades
	    SUM(CASE WHEN t.prioridade IN (0,1) THEN 1 ELSE 0 END)  AS qt_prioridade_normal,
	    SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END)       AS qt_prioridade_parcial,
	    SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END)       AS qt_prioridade_urgente,
	    SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END)       AS qt_prioridade_maxima,
	    SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END)       AS qt_prioridade_reforco,
	    SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS perc_prioridade_maxima
	
	FROM tb_conslida_tarefas t
	GROUP BY t.cod_cliente
)

SELECT
c.cod_cliente,
c.valor_contrato AS valor_medio_contrato,
-- c.primeira_assinatura,
-- c.data_cancelamento,

CASE
    WHEN c.churn = 1
        THEN TIMESTAMPDIFF(MONTH, c.primeira_assinatura, c.data_cancelamento)
    ELSE TIMESTAMPDIFF(MONTH, c.primeira_assinatura, CURDATE())
END AS meses_vida_cliente,

-- Features de tarefas
COALESCE(f.qt_tarefas_total, 	0)	AS qt_tarefas_total,
COALESCE(f.media_dias_exec, 	0)	AS media_dias_exec,

COALESCE(f.qt_tarefas_sd,               0)    AS qt_tarefas_sd,
COALESCE(f.media_dias_exec_tarefa_sd,   0)    AS media_dias_exec_tarefa_sd,
COALESCE((f.qt_tarefas_sd * 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_tarefas_sd,

COALESCE(f.qt_tarefas_hd,               0)    AS qt_tarefas_hd,
COALESCE(f.media_dias_exec_tarefa_hd,   0)    AS media_dias_exec_tarefa_hd,
COALESCE((f.qt_tarefas_hd * 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_tarefas_hd,

COALESCE(f.qt_tarefas_reclamacao,       0)    AS qt_tarefas_reclamacao,
COALESCE(f.media_dias_exec_reclamacao,  0)    AS media_dias_exec_reclamacao,
COALESCE((f.qt_tarefas_reclamacao * 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_tarefas_reclamacao,

COALESCE(f.qt_tarefas_reducao,      0)      AS qt_tarefas_reducao,
COALESCE(f.media_dias_exec_reducao, 0)      AS media_dias_exec_reducao,
COALESCE((f.qt_tarefas_reducao * 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_tarefas_reducao,

COALESCE(f.qt_tarefas_bug,      0)          AS qt_tarefas_bug,
COALESCE(f.media_dias_exec_bug, 0)          AS media_dias_exec_bug,
COALESCE((f.qt_tarefas_bug * 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_tarefas_bug,

COALESCE(f.qt_categorias_distintas,    0)    AS qt_categorias_distintas,
COALESCE(f.qt_subcategorias_distintas, 0)    AS qt_subcategorias_distintas,
COALESCE(f.qt_grupos_envolvidos,       0)    AS qt_grupos_envolvidos,

COALESCE((f.qt_prioridade_normal   	* 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_prioridade_normal,
COALESCE((f.qt_prioridade_parcial  	* 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_prioridade_parcial,
COALESCE((f.qt_prioridade_urgente  	* 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_prioridade_urgente,
COALESCE((f.qt_prioridade_maxima  	* 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_prioridade_maxima,
COALESCE((f.qt_prioridade_reforco 	* 1.0 / f.qt_tarefas_total) * 100, 0) AS perc_qt_prioridade_reforco,      

-- TARGET (y)
c.churn

FROM tb_clientes c
LEFT JOIN tb_features f ON c.cod_cliente = f.cod_cliente
-- HAVING media_dias_exec >= 0 AND meses_vida_cliente >= 0
HAVING media_dias_exec > 0 AND churn = 0
ORDER BY media_dias_exec ASC
;