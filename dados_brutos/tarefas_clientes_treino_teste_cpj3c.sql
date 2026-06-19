SET @cod_cliente = 17029;

WITH tb_produtos_contratos AS(
	SELECT 
		cad.codigo AS cod_cliente,
		COALESCE(com.nomecli, com.empresa) AS nome_cliente,
		
	    cad.id_contrato,
	    cad.status,
	    
	    DATE(cad.data_assinatura) AS data_primeira_assinatura,
	    
	    MAX(
			CASE
				WHEN cad.status = 4
					THEN DATE(COALESCE(con.cancelamento, cad.data_vencimento))
					ELSE NULL
				END
			) AS data_ultimo_cancelamento,
	    
		CASE
			WHEN tic.grupo_produto LIKE ''
				THEN 'NÃO CONSTA'
			ELSE tic.grupo_produto
		END AS grupo_produto,
	    
		CASE
			WHEN tic.grupo_produto LIKE 'CPJ-3C'
				THEN 1
			ELSE 0
		END AS flag_cpj,
		
	    SUM(cci.valor * cci.quantidade) AS valor_contrato
	    
	FROM 	   	cliwcs.cad_contrato		  	cad
	INNER JOIN 	cliwcs.cad_contrato_itens  	cci ON cad.id_contrato 	= cci.id_contrato
	LEFT JOIN 	cliwcs.tab_item_contrato   	tic ON cci.item 		= tic.codigo
	LEFT JOIN 	gecobi2.consolida_contratos con ON cad.id_contrato 	= con.idcontrato
	INNER JOIN 	gecobi2.comercial_tb 	  	com ON cad.codigo 		= com.cod_cad
	
	WHERE 1=1
		AND	cad.codigo NOT IN (8433,27710,34000,36363,36511,28306,37187,36603,35653,19620,43194) -- Preâmbulo
		AND cad.status IN (3, 4) -- Contratos Ativos e Cancelados
-- 		AND cad.codigo = @cod_cliente
	
	GROUP BY
		cad.codigo,
	    cad.id_contrato,
	    cad.status,
	    cad.data_assinatura,
	    cci.item,
	    tic.descricao,
	    tic.grupo_produto
),

tb_qt_usuarios AS(
	SELECT 
		cad.codigo AS cod_cliente,
		cad.id_contrato,
	    SUM(cci.quantidade) AS total_usuarios
	    
	FROM 	   cliwcs.cad_contrato		  	cad
	LEFT JOIN cliwcs.cad_contrato_itens  	cci ON cad.id_contrato 	= cci.id_contrato
	LEFT JOIN cliwcs.tab_item_contrato   	tic ON cci.item 		= tic.codigo
	LEFT JOIN cliwcs.tab_status_contrato 	tsc ON cad.status 		= tsc.codigo
	LEFT JOIN gecobi2.consolida_contratos 	con ON cad.id_contrato 	= con.idcontrato
	LEFT JOIN gecobi2.comercial_tb 			com ON cad.codigo		= com.cod_cad
	
	WHERE cad.codigo NOT IN (8433, 27710, 34000,
							 36363, 36511, 28306,
							 37187, 36603, 35653, 19620
							) -- Preâmbulo
		AND cad.status IN (3, 4) -- Contratos Ativos e Cancelados
		-- Apenas produtos que têm usuários
-- 		AND cad.codigo = @cod_cliente
		AND cci.item IN (
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
	GROUP BY
	    cad.codigo,
	    cad.id_contrato,
	    cci.item
)

-- SELECT * FROM tb_produtos_contratos WHERE cod_cliente = 15622

SELECT
	tpc.cod_cliente,
	tpc.nome_cliente,
	tpc.id_contrato,
	tpc.grupo_produto,
	tpc.flag_cpj,
	
	CASE
		WHEN MAX(tpc.status) = 4
			THEN 1
		ELSE 0
	END AS churn,
	
	MAX(tpc.data_primeira_assinatura) AS data_primeira_assinatura,
	MAX(tpc.data_ultimo_cancelamento) AS data_ultimo_cancelamento,
	
	SUM(tpc.valor_contrato) AS valor_contrato,
	tqu.total_usuarios
    
FROM tb_produtos_contratos tpc
LEFT JOIN tb_qt_usuarios tqu ON tpc.id_contrato = tqu.id_contrato
WHERE tpc.cod_cliente = @cod_cliente
GROUP BY tpc.id_contrato, tpc.cod_cliente
HAVING tpc.flag_cpj = 1
	