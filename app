# -*- coding: utf-8 -*-

import os
import sys
import time
import shutil
import subprocess
from pathlib import Path

# ============================================================
# MAPA DE CENÁRIOS ESTÁTICOS
# ============================================================
MAPA_CENARIOS = {
    "TTT": {"Inverter_Filtro_Estocastico1": "true",  "Inverter_Filtro_ADX1": "true",  "Inverter_Estrategia": "true"},
    "TTF": {"Inverter_Filtro_Estocastico1": "true",  "Inverter_Filtro_ADX1": "true",  "Inverter_Estrategia": "false"},
    "TFT": {"Inverter_Filtro_Estocastico1": "true",  "Inverter_Filtro_ADX1": "false", "Inverter_Estrategia": "true"},
    "TFF": {"Inverter_Filtro_Estocastico1": "true",  "Inverter_Filtro_ADX1": "false", "Inverter_Estrategia": "false"},
    "FTT": {"Inverter_Filtro_Estocastico1": "false", "Inverter_Filtro_ADX1": "true",  "Inverter_Estrategia": "true"},
    "FTF": {"Inverter_Filtro_Estocastico1": "false", "Inverter_Filtro_ADX1": "true",  "Inverter_Estrategia": "false"},
    "FFT": {"Inverter_Filtro_Estocastico1": "false", "Inverter_Filtro_ADX1": "false", "Inverter_Estrategia": "true"},
    "FFF": {"Inverter_Filtro_Estocastico1": "false", "Inverter_Filtro_ADX1": "false", "Inverter_Estrategia": "false"},
}

# ============================================================
# CLASSE PRINCIPAL DO MOTOR (Integrada com a GUI)
# ============================================================
class WFEManager:
    def __init__(self, config_dados, log_callback, progress_callback, is_running_callback):
        # Callbacks de Comunicação com a Interface
        self.log = log_callback
        self.progress = progress_callback
        self.is_running = is_running_callback

        # Dados oriundos da Interface (Dicionário do app.py)
        self.EA_NAME = config_dados['ea_name']
        self.SYMBOL = config_dados['symbol']
        self.PERIOD = config_dados['period_val']
        self.N_JANELAS = config_dados['n_janelas']
        self.TRAIN_UNTIL_YEAR = config_dados['train_until_year'] # <-- NOVA VARIÁVEL
        self.TRAIN_YEARS = config_dados['train_years']
        self.FORWARD_YEARS = config_dados['forward_years']
        self.PARAMS_OTIMIZADOS = config_dados['parametros_otimizados']
        self.CONFIGS_ATIVAS = config_dados['configuracoes_ativas']

        # Configurações Estáticas Internas do Motor
        self.OPTIMIZATION_MODE = 2
        self.OPTIMIZATION_CRITERION = 6
        self.REPLACE_EXISTING_REPORT = True
        self.XML_WAIT_SECONDS = 30

        self.EA_RELATIVE_PATH = Path("MQL5") / "Experts" / "Advisors" / f"{self.EA_NAME}.ex5"
        self.BASE_DIR = Path(__file__).resolve().parent
        self.RESULTS_DIR = self.BASE_DIR / "results"
        self.WALK_DIR = self.RESULTS_DIR / "walk_forward"
        
        self.RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        self.WALK_DIR.mkdir(parents=True, exist_ok=True)

        self.MT5_EXE = None

    # ========================================================
    # UTILITÁRIOS E DIRETÓRIOS
    # ========================================================
    def print_separator(self, char="=", length=70):
        self.log(char * length)

    def remove_file(self, path):
        path = Path(path)
        if path.exists():
            try:
                path.unlink()
                self.log(f"[OK] Arquivo antigo removido: {path.name}")
            except Exception as exc:
                raise RuntimeError(f"Não foi possível remover o arquivo: {path.name}\nErro: {exc}")

    def copy_file(self, source, destination):
        source, destination = Path(source), Path(destination)
        if not source.exists():
            raise RuntimeError(f"Arquivo de origem não encontrado:\n{source}")

        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            self.remove_file(destination)
        shutil.copy2(source, destination)
        return destination

    def wait_for_file(self, path, timeout_seconds):
        path = Path(path)
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if not self.is_running(): raise InterruptedError("Processo abortado pelo usuário.")
            if path.exists():
                try:
                    if path.stat().st_size > 0:
                        return True
                except OSError:
                    pass
            time.sleep(1)
        return False

    def build_windows(self):
        windows = []
        
        # --- ENGENHARIA REVERSA DO TEMPO ---
        # Calcula qual deve ser o ano inicial de modo que o FINAL do treino 
        # da última janela seja exatamente o 'TRAIN_UNTIL_YEAR'
        start_year = self.TRAIN_UNTIL_YEAR - self.TRAIN_YEARS - self.N_JANELAS + 1
        
        self.log(f"[MATEMÁTICA WFO] Janela 1 inicia em {start_year} para que o último Treino termine em {self.TRAIN_UNTIL_YEAR}.")

        for i in range(self.N_JANELAS):
            train_from_year = start_year + i
            train_to_year = train_from_year + self.TRAIN_YEARS
            forward_from_year = train_to_year
            forward_to_year = forward_from_year + self.FORWARD_YEARS

            windows.append((
                f"{train_from_year:04d}.01.01",
                f"{train_to_year:04d}.01.01",
                f"{forward_from_year:04d}.01.01",
                f"{forward_to_year:04d}.01.01",
            ))
        return windows

    def find_mt5_exe(self):
        candidates = [
            Path(r"C:\Program Files\MetaTrader 5\terminal64.exe"),
            Path(r"C:\Program Files (x86)\MetaTrader 5\terminal64.exe"),
        ]
        for candidate in candidates:
            if candidate.exists(): return candidate
        return None

    def find_ea_terminal(self):
        appdata = os.environ.get("APPDATA")
        if not appdata: return None, None
        root = Path(appdata) / "MetaQuotes" / "Terminal"
        if not root.exists(): return None, None

        matches = []
        for terminal_dir in root.iterdir():
            if not terminal_dir.is_dir(): continue
            ea_path = terminal_dir / self.EA_RELATIVE_PATH
            if ea_path.exists(): matches.append((terminal_dir, ea_path))

        if not matches: return None, None
        matches.sort(key=lambda item: item[1].stat().st_mtime, reverse=True)
        return matches[0]

    # ========================================================
    # GERAÇÃO INI E EXECUÇÃO
    # ========================================================
    def create_optimization_ini(self, path, train_from, train_to, forward_from, forward_to, report_name, configuracao):
        config = MAPA_CENARIOS.get(configuracao, {})
        content = f"""[Tester]
Expert=Advisors\\{self.EA_NAME}
Symbol={self.SYMBOL}
Period={self.PERIOD}
Model=2
Optimization={self.OPTIMIZATION_MODE}
OptimizationCriterion={self.OPTIMIZATION_CRITERION}
FromDate={train_from}
ToDate={forward_to}
ForwardMode=4
ProfitInPips=0
ForwardDate={forward_from}
Report={report_name}
ReplaceReport={1 if self.REPLACE_EXISTING_REPORT else 0}
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
Visual=0

[TesterInputs]
"""
        for chave, valor in config.items():
            content += f"{chave}={valor}||0||0||0||N\n"

        for param_name, (start, step, stop) in self.PARAMS_OTIMIZADOS.items():
            content += f"{param_name}={start}||{start}||{step}||{stop}||Y\n"

        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return content

    def run_mt5(self, config_file):
        command = [str(self.MT5_EXE), f"/config:{config_file}"]
        self.log("\nExecutando MetaTrader 5 em Background...")
        
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        
        started = time.time()
        while process.poll() is None:
            if not self.is_running():
                process.terminate()  # Mata o MT5 instantaneamente
                process.wait()
                raise InterruptedError("Motor interrompido. MT5 finalizado à força.")
            time.sleep(1)

        elapsed = time.time() - started
        if process.returncode != 0:
            raise RuntimeError(f"O MetaTrader 5 falhou (Código {process.returncode}). Verifique os relatórios.")
        
        self.log(f"[OK] Otimização MT5 concluída em {elapsed:.2f}s")

    # ========================================================
    # XML MANAGER
    # ========================================================
    def preserve_xml(self, terminal_data_dir, report_name, destination_dir, is_forward=False):
        sufixo = ".forward.xml" if is_forward else ".xml"
        source = Path(terminal_data_dir) / f"{report_name}{sufixo}"
        destination = Path(destination_dir) / f"{report_name}{sufixo}"

        self.log(f"Aguardando geração do relatorio: {source.name}...")
        if not self.wait_for_file(source, self.XML_WAIT_SECONDS):
            raise RuntimeError(f"O XML não foi gerado a tempo (Timeout {self.XML_WAIT_SECONDS}s).")

        self.copy_file(source, destination)
        self.log(f"[OK] Relatório salvo em: {destination.parent.name}")
        return destination

    def execute_window(self, configuracao, window_number, train_from, train_to, forward_from, forward_to, terminal_data_dir):
        self.print_separator("-")
        self.log(f"-> JANELA {window_number}/{self.N_JANELAS} | {train_from} a {forward_to}")

        window_dir = self.WALK_DIR / configuracao / f"janela_{window_number}"
        window_dir.mkdir(parents=True, exist_ok=True)
        
        report_name = f"otimizacao_{window_number}"
        ini_path = window_dir / f"{report_name}.ini"

        self.create_optimization_ini(ini_path, train_from, train_to, forward_from, forward_to, report_name, configuracao)
        self.run_mt5(ini_path)

        xml_back = self.preserve_xml(terminal_data_dir, report_name, window_dir, False)
        xml_forward = self.preserve_xml(terminal_data_dir, report_name, window_dir, True)

        return {
            "window": window_number,
            "xml": str(xml_back),
            "forward_xml": str(xml_forward),
        }

    # ========================================================
    # INTEGRAÇÃO ROBUSTNESS
    # ========================================================
    def run_robustness(self, configuracao, results, terminal_data_dir):
        robustness_path = self.BASE_DIR / "robustness.py"
        if not robustness_path.exists():
            self.log("\n[AVISO] Script robustness.py não encontrado. Pulando análise.")
            return

        self.log("\nPreparando relatórios para Análise de Robustez...")
        for item in results:
            self.copy_file(item["xml"], Path(terminal_data_dir) / f"otimizacao_{item['window']}.xml")
            self.copy_file(item["forward_xml"], Path(terminal_data_dir) / f"otimizacao_{item['window']}.forward.xml")

        parametros_str = ",".join(self.PARAMS_OTIMIZADOS.keys())
        command = [sys.executable, str(robustness_path), configuracao, parametros_str, self.EA_NAME]

        self.log(f"Iniciando Robustness Analyzer para {configuracao}...")
        process = subprocess.Popen(command, cwd=str(self.BASE_DIR))
        
        while process.poll() is None:
            if not self.is_running():
                process.terminate()
                raise InterruptedError("Análise de Robustez abortada.")
            time.sleep(1)

        if process.returncode == 0:
            self.log(f"[OK] Gráficos de Robustez gerados com sucesso para {configuracao}!")
        else:
            self.log(f"[ERRO] O Robustness falhou com código {process.returncode}.")

    # ========================================================
    # MOTOR PRINCIPAL (CHAMADO PELA GUI)
    # ========================================================
    def run_all(self):
        self.log(f"\n[SISTEMA] Procurando instalação MT5 e o EA '{self.EA_NAME}'...")
        
        self.MT5_EXE = self.find_mt5_exe()
        if not self.MT5_EXE: raise RuntimeError("Terminal MetaTrader 5 não encontrado!")
        
        terminal_data_dir, ea_path = self.find_ea_terminal()
        if not terminal_data_dir: raise RuntimeError(f"O EA '{self.EA_NAME}.ex5' não foi encontrado na pasta Experts.")

        # Constrói as janelas com a nova regra matemática
        windows = self.build_windows()
        
        total_passos = len(self.CONFIGS_ATIVAS) * self.N_JANELAS
        passo_atual = 0

        self.log("[SISTEMA] Ambiente Validado. Iniciando Loop Otimizador.")

        for configuracao in self.CONFIGS_ATIVAS:
            if not self.is_running(): raise InterruptedError("Abortado pelo usuário.")
            
            self.log("\n")
            self.print_separator()
            self.log(f"🚀 INICIANDO CENÁRIO: {configuracao}")
            self.print_separator()

            config_results = []
            for i, window in enumerate(windows, start=1):
                if not self.is_running(): raise InterruptedError("Abortado pelo usuário.")
                
                res = self.execute_window(configuracao, i, window[0], window[1], window[2], window[3], terminal_data_dir)
                config_results.append(res)
                
                passo_atual += 1
                self.progress(passo_atual, total_passos)
                
            self.run_robustness(configuracao, config_results, terminal_data_dir)

        self.log("\n")
        self.print_separator()
        self.log("✅ WFO E ROBUSTNESS CONCLUÍDOS COM SUCESSO!")
        self.log(f"Todos os dados foram salvos na pasta:\n{self.WALK_DIR}")
        self.print_separator()

import sys
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                             QHBoxLayout, QFormLayout, QGridLayout, QLineEdit, 
                             QComboBox, QSpinBox, QPushButton, QTableWidget, 
                             QTableWidgetItem, QHeaderView, QCheckBox, QTextEdit, 
                             QProgressBar, QLabel, QGroupBox, QMessageBox)
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtGui import QFont

# ============================================================
# 1. A THREAD DE EXECUÇÃO (Trabalhador em Segundo Plano)
# ============================================================
class TrabalhadorWFO(QThread):
    sinal_log = pyqtSignal(str)
    sinal_fim = pyqtSignal()
    sinal_progresso = pyqtSignal(int, int)

    def __init__(self, dados_config):
        super().__init__()
        self.dados = dados_config
        self._esta_rodando = True  

    def run(self):
        try:
            motor = WFEManager(
                config_dados = self.dados,
                log_callback = self.sinal_log.emit,
                progress_callback = self.sinal_progresso.emit,
                is_running_callback = lambda: self._esta_rodando
            )
            motor.run_all()
            self.sinal_fim.emit()
            
        except InterruptedError as e:
            self.sinal_log.emit(f"\n[🛑 ALERTA] {str(e)}")
            self.sinal_fim.emit()
            
        except Exception as e:
            self.sinal_log.emit(f"\n[❌ ERRO FATAL] {str(e)}")
            self.sinal_fim.emit()

    def parar(self):
        self._esta_rodando = False


# ============================================================
# 2. A INTERFACE PRINCIPAL (Cockpit)
# ============================================================
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Cockpit Quant - Walk-Forward Manager")
        self.resize(1350, 850)
        
        self.aplicar_estilo_qss()

        widget_central = QWidget()
        self.setCentralWidget(widget_central)
        layout_principal = QHBoxLayout(widget_central)
        layout_principal.setContentsMargins(20, 20, 20, 20)
        layout_principal.setSpacing(20)

        # Divisão da Tela
        layout_principal.addWidget(self.criar_modulo_1(), 1) 
        layout_principal.addWidget(self.criar_modulo_2(), 2) 
        layout_principal.addWidget(self.criar_modulo_3(), 2) 

    # --------------------------------------------------------
    # MÓDULO 1: Configuração Geral e WFO
    # --------------------------------------------------------
    def criar_modulo_1(self):
        grupo = QGroupBox("1. Identidade e Tempo")
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)
        form = QFormLayout()
        form.setSpacing(12)

        self.input_ea = QLineEdit("Bollinger")
        self.input_ativo = QLineEdit("EURUSD_custom")
        
        self.combo_timeframe = QComboBox()
        tfs = [("M1", 1), ("M5", 5), ("M15", 15), ("M30", 30), 
               ("H1", 60), ("H4", 240), ("D1", 1440)]
        for nome, valor in tfs:
            self.combo_timeframe.addItem(nome, valor)
        self.combo_timeframe.setCurrentText("M30")

        # --- AQUI ENTRA A MUDANÇA DA INTERFACE ---
        self.spin_ano = QSpinBox()
        self.spin_ano.setRange(2000, 2050)
        self.spin_ano.setValue(2025) # Coloquei 2025 como padrão

        self.spin_treino = QSpinBox()
        self.spin_treino.setRange(1, 10)
        self.spin_treino.setValue(4)

        self.spin_forward = QSpinBox()
        self.spin_forward.setRange(1, 10)
        self.spin_forward.setValue(1)

        self.spin_janelas = QSpinBox()
        self.spin_janelas.setRange(1, 20)
        self.spin_janelas.setValue(6)

        form.addRow("Nome do EA:", self.input_ea)
        form.addRow("Ativo:", self.input_ativo)
        form.addRow("Timeframe:", self.combo_timeframe)
        form.addRow(QLabel(" ")) # Espaçador
        form.addRow("Ano Alvo Final:", self.spin_ano)
        form.addRow("Anos Treino:", self.spin_treino)
        form.addRow("Anos Forward:", self.spin_forward)
        form.addRow("Qtd Janelas:", self.spin_janelas)

        layout.addLayout(form)
        layout.addStretch() 
        return grupo

    # --------------------------------------------------------
    # MÓDULO 2: Tabela de Parâmetros e Cenários
    # --------------------------------------------------------
    def criar_modulo_2(self):
        grupo = QGroupBox("2. Laboratório de DNA")
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)

        # --- A. Tabela de Otimização ---
        layout.addWidget(QLabel("Parâmetros Otimizados:"))
        self.tabela = QTableWidget()
        self.tabela.setColumnCount(4)
        self.tabela.setHorizontalHeaderLabels(["Variável", "Start", "Step", "Stop"])
        self.tabela.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch) 
        
        self.tabela.setAlternatingRowColors(True)
        self.tabela.verticalHeader().setVisible(False)
        self.tabela.verticalHeader().setDefaultSectionSize(40)

        params_iniciais = [
            ("Espacamento_Filtro_Estocastico1", "1", "1", "99"),
            ("Periodo_Filtro_Estocastico1", "1", "1", "300"),
            ("Linha_Filtro_ADX1", "1", "1", "99"),
            ("Periodo_Filtro_ADX1", "1", "1", "99"),
            ("Periodo_BollingerBands1", "1", "1", "300"),
            ("Desvio_BollingerBands1", "0.4", "0.1", "4.0")
        ]
        
        self.tabela.setRowCount(len(params_iniciais))
        for row, (nome, start, step, stop) in enumerate(params_iniciais):
            self.tabela.setItem(row, 0, QTableWidgetItem(nome))
            self.tabela.setItem(row, 1, QTableWidgetItem(start))
            self.tabela.setItem(row, 2, QTableWidgetItem(step))
            self.tabela.setItem(row, 3, QTableWidgetItem(stop))

        # Botões da tabela
        botoes_tabela = QHBoxLayout()
        btn_add = QPushButton("+ Adicionar Parâmetro")
        btn_add.clicked.connect(self.adicionar_linha_tabela)
        
        btn_del = QPushButton("- Remover Parâmetro")
        btn_del.clicked.connect(self.remover_linha_tabela)
        
        botoes_tabela.addWidget(btn_add)
        botoes_tabela.addWidget(btn_del)

        layout.addWidget(self.tabela)
        layout.addLayout(botoes_tabela)

        # --- B. Cenários (Os 8 possíveis) ---
        layout.addWidget(QLabel("\nCenários de Configuração Ativos:"))
        self.grupo_cenarios = QWidget()
        grade_cenarios = QGridLayout(self.grupo_cenarios)
        grade_cenarios.setSpacing(15)
        
        cenarios_nomes = ["TTT", "TTF", "TFT", "TFF", "FTT", "FTF", "FFT", "FFF"]
        self.check_cenarios = {}
        
        linha, coluna = 0, 0
        for cenario in cenarios_nomes:
            chk = QCheckBox(cenario)
            chk.setChecked(True if cenario == "TTT" else False)
            self.check_cenarios[cenario] = chk
            grade_cenarios.addWidget(chk, linha, coluna)
            
            coluna += 1
            if coluna > 3:
                coluna = 0
                linha += 1

        layout.addWidget(self.grupo_cenarios)
        return grupo

    # --------------------------------------------------------
    # MÓDULO 3: Telemetria e Execução
    # --------------------------------------------------------
    def criar_modulo_3(self):
        grupo = QGroupBox("3. Centro de Controle")
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)

        # Caixa Preta (Console)
        self.console = QTextEdit()
        self.console.setReadOnly(True)
        self.console.setObjectName("consoleMatrix")
        self.console.setFont(QFont("Consolas", 12))
        self.console.append("SISTEMA PRONTO.\nAGUARDANDO COMANDO PARA DECOLAGEM...")

        # Barra de Progresso
        self.barra_progresso = QProgressBar()
        self.barra_progresso.setValue(0)
        self.barra_progresso.setTextVisible(True)
        self.barra_progresso.setFormat("Aguardando... %p%")

        # Botões Executores
        botoes_layout = QHBoxLayout()
        botoes_layout.setSpacing(15)
        
        self.btn_iniciar = QPushButton("🚀 INICIAR WFO")
        self.btn_iniciar.setObjectName("btnIniciar")
        self.btn_iniciar.clicked.connect(self.iniciar_operacao)

        self.btn_parar = QPushButton("🛑 ABORTAR")
        self.btn_parar.setObjectName("btnParar")
        self.btn_parar.setEnabled(False)
        self.btn_parar.clicked.connect(self.parar_operacao)

        botoes_layout.addWidget(self.btn_iniciar)
        botoes_layout.addWidget(self.btn_parar)

        layout.addWidget(QLabel("Terminal de Eventos do Sistema:"))
        layout.addWidget(self.console)
        layout.addWidget(self.barra_progresso)
        layout.addLayout(botoes_layout)
        
        return grupo

    # --------------------------------------------------------
    # FUNÇÕES AUXILIARES
    # --------------------------------------------------------
    def adicionar_linha_tabela(self):
        linha_atual = self.tabela.rowCount()
        self.tabela.insertRow(linha_atual)
        for col in range(4):
            self.tabela.setItem(linha_atual, col, QTableWidgetItem(""))

    def remover_linha_tabela(self):
        linha_selecionada = self.tabela.currentRow()
        if linha_selecionada >= 0:
            self.tabela.removeRow(linha_selecionada)
        else:
            QMessageBox.warning(self, "Aviso", "Selecione uma linha para remover.")

    def capturar_dados(self):
        parametros = {}
        for row in range(self.tabela.rowCount()):
            nome = self.tabela.item(row, 0).text().strip() if self.tabela.item(row, 0) else ""
            if not nome: continue
            try:
                start = self.tabela.item(row, 1).text()
                step = self.tabela.item(row, 2).text()
                stop = self.tabela.item(row, 3).text()
                parametros[nome] = (float(start), float(step), float(stop))
            except ValueError:
                QMessageBox.warning(self, "Erro de Conversão", f"Valores incorretos na variável: {nome}. Use números.")
                return None

        configs_ativas = [nome for nome, chk in self.check_cenarios.items() if chk.isChecked()]

        return {
            "ea_name": self.input_ea.text().strip(),
            "symbol": self.input_ativo.text().strip(),
            "period_val": self.combo_timeframe.currentData(),
            "train_until_year": self.spin_ano.value() -1, # <-- NOME ALTERADO AQUI
            "train_years": self.spin_treino.value(),
            "forward_years": self.spin_forward.value(),
            "n_janelas": self.spin_janelas.value(),
            "parametros_otimizados": parametros,
            "configuracoes_ativas": configs_ativas
        }

    def iniciar_operacao(self):
        dados = self.capturar_dados()
        if dados is None: return  

        if not dados['configuracoes_ativas']:
            QMessageBox.critical(self, "Erro", "Marque pelo menos UM cenário ativo (Ex: TTT)!")
            return
        if not dados['parametros_otimizados']:
            QMessageBox.critical(self, "Erro", "A tabela de parâmetros não pode estar vazia!")
            return

        self.btn_iniciar.setEnabled(False)
        self.btn_parar.setEnabled(True)
        self.console.clear()
        self.barra_progresso.setValue(0)
        self.barra_progresso.setFormat("Executando MT5... %p%")
        
        self.worker = TrabalhadorWFO(dados)
        self.worker.sinal_log.connect(self.console.append)
        self.worker.sinal_progresso.connect(self.atualizar_progresso)
        self.worker.sinal_fim.connect(self.finalizar_operacao)
        self.worker.start()

    def parar_operacao(self):
        self.btn_parar.setEnabled(False)
        self.console.append("\n[SISTEMA] Solicitando cancelamento forçado ao MT5...")
        if hasattr(self, 'worker') and self.worker.isRunning():
            self.worker.parar()

    def atualizar_progresso(self, atual, total):
        self.barra_progresso.setMaximum(total)
        self.barra_progresso.setValue(atual)

    def finalizar_operacao(self):
        self.btn_iniciar.setEnabled(True)
        self.btn_parar.setEnabled(False)
        
        if self.barra_progresso.value() == self.barra_progresso.maximum() and self.barra_progresso.maximum() > 0:
            self.barra_progresso.setFormat("Processo Finalizado. 100%")
        else:
            self.barra_progresso.setFormat("Processo Interrompido/Falhou.")

    # --------------------------------------------------------
    # ESTILIZAÇÃO QSS - NOVO DESIGN PREMIUM
    # --------------------------------------------------------
    def aplicar_estilo_qss(self):
        estilo = """
        /* ==================== GLOBAL ==================== */
        * {
            font-family: 'Segoe UI', 'Roboto', 'Helvetica', sans-serif;
            font-size: 14px;
        }
        QMainWindow {
            background-color: #121216; /* Fundo principal escuro profundo */
        }
        QLabel {
            color: #A0AABF; /* Texto secundário suave */
            font-weight: 600;
        }

        /* ==================== CAIXAS DE GRUPO ==================== */
        QGroupBox {
            color: #61AFEF; /* Azul ciano marcante */
            font-size: 16px;
            font-weight: 900;
            border: 1px solid #282C34;
            border-radius: 8px;
            margin-top: 25px;
            padding: 20px 15px 15px 15px;
            background-color: #181A1F; /* Fundo interno do bloco */
        }
        QGroupBox::title {
            subcontrol-origin: margin;
            left: 15px;
            top: -10px;
            padding: 0 8px;
            background-color: #121216; /* Tapa o contorno em volta do texto */
        }

        /* ==================== INPUTS ==================== */
        QLineEdit, QSpinBox, QComboBox { 
            background-color: #21252B; 
            color: #D7DAE0; 
            border: 1px solid #333842; 
            padding: 8px 12px; 
            border-radius: 6px;
            font-size: 15px;
        }
        QLineEdit:focus, QSpinBox:focus, QComboBox:focus {
            border: 1px solid #61AFEF; /* Brilho azul ao clicar */
        }
        QComboBox::drop-down { border: none; }
        QComboBox QAbstractItemView { 
            background-color: #21252B; 
            color: #D7DAE0; 
            selection-background-color: #61AFEF; 
        }

        /* ==================== TABELA ==================== */
        QTableWidget { 
            background-color: #1E2227; 
            alternate-background-color: #21252B; /* Linhas zebradas */
            color: #D7DAE0; 
            gridline-color: #282C34; 
            border: 1px solid #333842; 
            border-radius: 6px;
            font-size: 14px;
        }
        QHeaderView::section { 
            background-color: #181A1F; 
            color: #ABB2BF; 
            padding: 8px; 
            border: none; 
            border-right: 1px solid #282C34;
            border-bottom: 2px solid #61AFEF; /* Linha de destaque no cabeçalho */
            font-weight: bold;
            font-size: 14px;
        }

        /* ==================== CHECKBOX (Toggles) ==================== */
        QCheckBox { 
            color: #ABB2BF; 
            font-size: 15px; 
            font-weight: 600; 
        }
        QCheckBox::indicator { width: 22px; height: 22px; }
        QCheckBox::indicator:unchecked { 
            border: 2px solid #4C566A; 
            background: #21252B; 
            border-radius: 5px; 
        }
        QCheckBox::indicator:checked { 
            border: 2px solid #98C379; 
            background: #98C379; 
            border-radius: 5px; 
        }

        /* ==================== CONSOLE ==================== */
        #consoleMatrix { 
            background-color: #0E1013; 
            color: #98C379; /* Verde Hacker Suave */
            border: 2px inset #1E2227; 
            border-radius: 6px;
            padding: 15px; 
            selection-background-color: #98C379;
            selection-color: #000;
        }

        /* ==================== PROGRESS BAR ==================== */
        QProgressBar { 
            border: 1px solid #333842; 
            border-radius: 8px; 
            text-align: center; 
            color: white; 
            font-weight: bold; 
            font-size: 15px;
            background-color: #181A1F;
            min-height: 25px;
        }
        QProgressBar::chunk { 
            background-color: qlineargradient(x1: 0, y1: 0, x2: 1, y2: 0, stop: 0 #61AFEF, stop: 1 #C678DD); /* Degradê azul para roxo */
            border-radius: 7px;
        }

        /* ==================== BOTÕES ==================== */
        QPushButton { 
            background-color: #282C34; 
            color: #ABB2BF; 
            border-radius: 6px; 
            padding: 10px; 
            font-weight: bold; 
            font-size: 14px;
            border: 1px solid #333842;
        }
        QPushButton:hover { background-color: #3E4452; color: #FFF; }

        /* Botões Gigantes */
        #btnIniciar { 
            background-color: #98C379; 
            color: #121216;
            font-size: 18px; 
            font-weight: 900;
            padding: 18px; 
            border: none;
        }
        #btnIniciar:hover { background-color: #7CB35F; }
        #btnIniciar:disabled { background-color: #2A3624; color: #666; }
        
        #btnParar { 
            background-color: #E06C75; 
            color: #121216;
            font-size: 18px; 
            font-weight: 900;
            padding: 18px; 
            border: none;
        }
        #btnParar:hover { background-color: #C85961; }
        #btnParar:disabled { background-color: #4A282B; color: #666; }

        /* ==================== SCROLLBARS (Rolagem) ==================== */
        QScrollBar:vertical {
            border: none;
            background: #181A1F;
            width: 12px;
            border-radius: 6px;
        }
        QScrollBar::handle:vertical {
            background: #3E4452;
            min-height: 20px;
            border-radius: 6px;
        }
        QScrollBar::handle:vertical:hover { background: #61AFEF; }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { border: none; background: none; }
        """
        self.setStyleSheet(estilo)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    janela = MainWindow()
    janela.show()
    sys.exit(app.exec_())
