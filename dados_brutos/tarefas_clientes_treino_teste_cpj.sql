SET @cod_cliente = 125;

WITH tb_produtos_contratos AS(
	SELECT 
		cad.codigo AS cod_cliente,
		COALESCE(com.nomecli, com.empresa) AS nome_cliente,
		
	    cad.id_contrato,
	    cad.status,
	    
	    DATE(cad.data_assinatura) AS data_assinatura,
	    
	    MAX(
			CASE
				WHEN cad.status = 4
					THEN DATE(COALESCE(con.cancelamento, cad.data_vencimento))
					ELSE NULL
				END
			) AS data_cancelamento,
	    
		COALESCE(NULLIF(tic.grupo_produto, ''), 'NÃO CONSTA') AS grupo_produto,
	    
		CASE
			WHEN tic.grupo_produto LIKE '%CPJ%'
				THEN 1
			ELSE 0
		END AS flag_cpj,
		
		SUM(cci.quantidade * cci.valor) AS valor_contrato,
	    
	    SUM(
			CASE
		    	WHEN cci.item IN (
		                     2,     -- CPJ-3C (up-grade)
		                     20,    -- CPJ-3C (SMART)
		                     24,    -- CPJ-3C  USUÁRIOS ADICIONAIS
		                     109,   -- CPJ-3C (Campanha)
		                     10022, -- CPJ Mini
		                     139,   -- CPJ-COBRANÇA USUÁRIO ADICIONAL
		                     50,    -- CPJ Cobrança Usu.
		                     10023, -- Pacote Cobrança Mini
		                     10012, -- Office Usuários
		                     10095  -- Office - Plano  Pró
							 ) -- Produtos que contém usuários
					THEN cci.quantidade
				ELSE 0
			END) AS total_usuarios
	    
	FROM 	   	cliwcs.cad_contrato		  	cad
	INNER JOIN 	cliwcs.cad_contrato_itens  	cci ON cad.id_contrato 	= cci.id_contrato
	LEFT JOIN 	cliwcs.tab_item_contrato   	tic ON cci.item 		= tic.codigo
	LEFT JOIN 	gecobi2.consolida_contratos con ON cad.id_contrato 	= con.idcontrato
	INNER JOIN 	gecobi2.comercial_tb 	  	com ON cad.codigo 		= com.cod_cad
	
	WHERE cad.codigo NOT IN (8433,27710,34000,36363,36511,28306,37187,36603,35653,19620,43194) -- Preâmbulo
		AND cad.status IN (3, 4) -- Contratos Ativos e Cancelados
-- 		AND cad.codigo = @cod_cliente
	
	GROUP BY
	    cad.codigo,
	    COALESCE(com.nomecli, com.empresa),
	    cad.id_contrato,
	    cad.status,
	    cad.data_assinatura
	
	HAVING flag_cpj = 1
		AND valor_contrato > 0
		AND total_usuarios  > 0
		
),

tb_consolida_contratos AS(
	SELECT
		tpc.*,

		CASE
			WHEN tpc.grupo_produto LIKE '%CPJ-3C%'
				THEN 67
			WHEN tpc.grupo_produto LIKE '%CPJ-COB%'
				THEN 18
		END AS cod_gr_produto,
			
		AVG(tpc.valor_contrato) AS valor_medio_contrato,
		AVG(tpc.total_usuarios) AS media_usuarios,
		
		AVG(
			TIMESTAMPDIFF(
				MONTH,
				tpc.data_assinatura,
				COALESCE(tpc.data_cancelamento, CURDATE())
			)) AS meses_vida_contrato,
		
		CASE
			WHEN tpc.status = 4
				THEN 1
			ELSE 0
		END AS churn
	    
	FROM tb_produtos_contratos tpc
-- 	WHERE tpc.cod_cliente = @cod_cliente
	GROUP BY tpc.cod_cliente, tpc.grupo_produto
	HAVING meses_vida_contrato > 0 -- Motivo: Há datas de cancelamento com erro
),

tb_tarefas AS (
    -- Base de tarefas com classificação de atrito e eficiência
    SELECT
        tcc.*,
        otb.data_cad,
        otb.data_exe,
        -- Blindagem contra o outlier de dias negativos
		CASE
		    WHEN otb.data_exe IS NOT NULL AND otb.data_exe >= otb.data_cad 
		    THEN DATEDIFF(otb.data_exe, otb.data_cad)
		    ELSE NULL -- Ignora inserções retroativas erradas
		END AS dias_exec_tarefa,
        otb.categoria,
        stv1.dst AS descr_categoria,
        otb.subcategoria,
        stv2.dst AS descr_subcategoria,
        otb.prioridade,
        utb.grupo_trabalho,
        
        -- Identificação de Status de Abertura
        CASE WHEN sto.sto NOT IN ('X', 'V') THEN 1 ELSE 0 END AS flag_aberta,

        -- Mapeamento das eficiências de tarefas já finalizadas (Para cálculo de médias históricas)
        CASE
            WHEN utb.grupo_trabalho IN (3, 29, 64) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_sd,

        CASE
            WHEN utb.grupo_trabalho IN (5, 23, 63) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_hd,

        CASE
            WHEN otb.categoria IN (304) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_reclamacao,

        CASE
            WHEN otb.categoria IN (18402, 18441, 18468) AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_reducao,

        CASE
            WHEN (LOWER(stv1.dst) LIKE '%bug%' OR LOWER(stv2.dst) LIKE '%bug%') AND sto.sto IN ('X', 'V') THEN DATEDIFF(otb.data_exe, otb.data_cad)
            ELSE NULL
        END AS dias_exec_tarefa_bug,
        
        otb.cod_ps

    FROM        tb_consolida_contratos	tcc
    LEFT JOIN	gecobi2.ordemser_tb		otb		ON tcc.cod_cliente	= otb.cliente
    											AND otb.cod_ps       = tcc.cod_gr_produto
    LEFT JOIN   gecobi2.stos_tb     	sto  	ON otb.stos         = sto.cod
    LEFT JOIN   gecobi2.usu_tb      	utb  	ON otb.para1        = utb.cod_usu
    LEFT JOIN   gecobi2.stven_tb    	stv1 	ON otb.categoria    = stv1.st
    LEFT JOIN   gecobi2.stven_tb    	stv2 	ON otb.subcategoria = stv2.st
    LEFT JOIN   gecobi2.produtos_tb 	ptb		ON otb.cod_ps 		= ptb.cod_ps
    

    WHERE otb.nros_sub = 0 -- Somente tarefas principais
		AND otb.cod_ps IN (18, 67) -- CPJ-COBRANÇA e CPJ-3C
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
    -- Agregação e inteligência de estoque de dor por tipo de cliente
    SELECT
		t.*,
        COUNT(*) AS qt_tarefas_total,
        MAX(t.data_cad) AS data_ultima_tarefa_real,

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
        SUM(CASE WHEN t.grupo_trabalho IN (3, 29, 64) THEN 1 ELSE 0 END) 		AS qt_tarefas_sd,
        SUM(CASE WHEN t.grupo_trabalho IN (5, 23, 63) THEN 1 ELSE 0 END) 		AS qt_tarefas_hd,
        SUM(CASE WHEN t.categoria IN (304) THEN 1 ELSE 0 END)            		AS qt_tarefas_reclamacao,
        SUM(CASE WHEN t.categoria IN (18402, 18441, 18468) THEN 1 ELSE 0 END) 	AS qt_tarefas_reducao,
        SUM(CASE WHEN LOWER(t.descr_categoria) LIKE '%bug%' OR LOWER(t.descr_subcategoria) LIKE '%bug%' THEN 1 ELSE 0 END) AS qt_tarefas_bug,

        -- Severidade de prioridades
        SUM(CASE WHEN t.prioridade IN (0,1) THEN 1 ELSE 0 END)  AS qt_prioridade_normal,
        SUM(CASE WHEN t.prioridade = 2 THEN 1 ELSE 0 END)       AS qt_prioridade_parcial,
        SUM(CASE WHEN t.prioridade = 3 THEN 1 ELSE 0 END)       AS qt_prioridade_urgente,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END)       AS qt_prioridade_maxima,
        SUM(CASE WHEN t.prioridade = 9 THEN 1 ELSE 0 END)       AS qt_prioridade_reforco,
        SUM(CASE WHEN t.prioridade = 4 THEN 1 ELSE 0 END) / COUNT(*) AS perc_prioridade_maxima

    FROM tb_tarefas t
    WHERE t.cod_ps IS NOT NULL
    	AND t.dias_exec_tarefa IS NOT NULL
	GROUP BY t.cod_cliente, t.cod_gr_produto, t.grupo_produto
)


SELECT
	c.cod_cliente,
	
	c.data_assinatura,
	c.data_cancelamento,
	c.meses_vida_contrato,
	
	c.grupo_produto,
	c.valor_medio_contrato,
	c.media_usuarios,
	

    -- FEATURES OPERACIONAIS DE SUPORTE
    COALESCE(c.qt_tarefas_total, 	0)	AS qt_tarefas_total,
    COALESCE(c.media_dias_exec,		0)  AS media_dias_exec,
    
    COALESCE(c.qt_tarefas_sd, 0)                AS qt_tarefas_sd,
    COALESCE(c.media_dias_exec_tarefa_sd, 0)    AS media_dias_exec_tarefa_sd,
    
    COALESCE(c.qt_tarefas_hd, 0)                AS qt_tarefas_hd,
    COALESCE(c.media_dias_exec_tarefa_hd, 0)    AS media_dias_exec_tarefa_hd,
    
    COALESCE(c.qt_tarefas_reclamacao, 0)        AS qt_tarefas_reclamacao,
    COALESCE(c.media_dias_exec_reclamacao, 0)   AS media_dias_exec_reclamacao,
    
    COALESCE(c.qt_tarefas_reducao, 0)           AS qt_tarefas_reducao,
    COALESCE(c.media_dias_exec_reducao, 0)      AS media_dias_exec_reducao,
    
    COALESCE(c.qt_tarefas_bug, 0)               AS qt_tarefas_bug,
    COALESCE(c.media_dias_exec_bug, 0)          AS media_dias_exec_bug,
    
    -- RECÊNCIA CONVERTIDA
    CASE 
        WHEN c.churn = 1 THEN 
            GREATEST(0, DATEDIFF(c.data_cancelamento, COALESCE(c.data_ultima_tarefa_real, c.data_assinatura)))
        ELSE 
            DATEDIFF(CURDATE(), COALESCE(c.data_ultima_tarefa_real, c.data_assinatura))
    END AS dias_ultima_tarefa,
    
    COALESCE(c.qt_categorias_distintas, 	0)	AS qt_categorias_distintas,
    COALESCE(c.qt_subcategorias_distintas,	0)  AS qt_subcategorias_distintas,
    COALESCE(c.qt_grupos_envolvidos,	 	0)  AS qt_grupos_envolvidos,

    COALESCE(c.qt_prioridade_normal,  0)        AS qt_prioridade_normal,
    COALESCE(c.qt_prioridade_parcial, 0)       	AS qt_prioridade_parcial,
    COALESCE(c.qt_prioridade_urgente, 0)       	AS qt_prioridade_urgente,
    COALESCE(c.qt_prioridade_maxima,  0)        AS qt_prioridade_maxima,
    COALESCE(c.qt_prioridade_reforco, 0)       	AS qt_prioridade_reforco,
    
    -- Target
    c.churn
    
FROM tb_features c
;

	