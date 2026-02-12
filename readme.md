# NetShooting

NetShooting é um script em PowerShell para troubleshooting de rede, criado para coletar e organizar informações de conectividade, DNS e testes de portas TCP de forma rápida e padronizada.  
Ele é indicado para diagnóstico técnico, verificação de falhas de rede e geração de evidências para suporte.
Disponibilizei o executável para donwload direto e também os scripts para possíveis adaptabilidade e implementações.

---

## Funcionalidades

- Teste de conectividade usando ping  
- Análise de rota com traceroute  
- Resolução de nomes DNS  
- Suporte a múltiplos alvos (endereços IP ou hostnames)  
- Geração automática de relatórios:
  - Resumo em texto
  - Arquivo JSON estruturado
- Opção para compactar todos os resultados em um único arquivo ZIP  

---

## Estrutura de Saída

Os resultados são armazenados em uma pasta criada nos Documentos do usuário, contendo data e hora no nome.  
Dentro dessa pasta ficam organizados os logs por alvo, além de um resumo geral e um arquivo JSON consolidado.  
Quando a opção de compactação é utilizada, todo o conteúdo é incluído em um único arquivo ZIP.

---

## Requisitos

- Windows com PowerShell versão 5.1 ou superior, ou PowerShell 7
- Permissão para executar o .exe  
- Permissão para execução de scripts configurada no sistema  
- Ferramentas nativas do Windows disponíveis:
  - ping
  - tracert
  - nslookup
  - Test-NetConnection  

---

## Parâmetros Disponíveis

- Targets  
  Lista de alvos que serão testados, podendo ser IPs ou nomes de host.

- TcpPorts  
  Portas TCP que serão verificadas durante os testes.  
  Caso não seja informado, são utilizadas portas padrão comuns de rede.

- DnsNames  
  Lista de nomes DNS adicionais para resolução, além dos próprios alvos.

- OutputDir  
  Diretório onde os arquivos de saída serão salvos.

- Zip  
  Ativa a compactação de todos os resultados em um arquivo ZIP.

---

## Casos de Uso

- Diagnóstico rápido de problemas de conectividade  
- Coleta de informações para equipes de suporte técnico  
- Verificação de DNS, firewall e portas abertas  
- Análise inicial de falhas de rota ou indisponibilidade de serviços  

---

## Observações de Segurança

- Execute o script apenas em redes e ambientes autorizados  
- Alguns testes podem ser bloqueados por firewalls ou políticas de segurança  
- O script não faz alterações no sistema, apenas coleta e registra informações

---

## Licença

Este projeto é distribuído como está.
Você pode modificar, adaptar e reutilizar livremente conforme suas necessidades.
