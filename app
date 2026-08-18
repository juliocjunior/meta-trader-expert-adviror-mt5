# -*- coding: utf-8 -*-

import sys
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                             QHBoxLayout, QFormLayout, QGridLayout, QLineEdit, 
                             QComboBox, QSpinBox, QPushButton, QTableWidget, 
                             QTableWidgetItem, QHeaderView, QCheckBox, QTextEdit, 
                             QProgressBar, QLabel, QGroupBox, QMessageBox)
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtGui import QFont

# Importamos o motor do arquivo manager.py
from manager import WFEManager

# ============================================================
# 1. A THREAD DE EXECUÇÃO (Trabalhador Multi-Timeframe)
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
            timeframes = self.dados['timeframes_selecionados']
            cenarios = self.dados['configuracoes_ativas']
            n_janelas = self.dados['n_janelas']

            # Cálculo do progresso total global
            total_global_passos = len(timeframes) * len(cenarios) * n_janelas
            passo_atual_global = 0

            for tf in timeframes:
                if not self._esta_rodando: break

                self.sinal_log.emit("\n" + "=" * 70)
                self.sinal_log.emit(f"🚀 INICIANDO CICLO TIMEFRAME: {tf['nome']}")
                self.sinal_log.emit("=" * 70)

                # Criamos uma cópia dos dados injetando o timeframe atual
                config_rodada = self.dados.copy()
                config_rodada['period_val'] = tf['valor']
                config_rodada['period_name'] = tf['nome']

                # Callback de progresso que atualiza a barra global
                def progress_callback_ajustado(passo_interno, total_interno):
                    self.sinal_progresso.emit(passo_atual_global + passo_interno, total_global_passos)

                motor = WFEManager(
                    config_dados = config_rodada,
                    log_callback = self.sinal_log.emit,
                    progress_callback = progress_callback_ajustado,
                    is_running_callback = lambda: self._esta_rodando
                )
                
                motor.run_all()

                # Incrementa o progresso global após cada timeframe concluído
                passo_atual_global += (len(cenarios) * n_janelas)

            self.sinal_log.emit("\n✅ [SISTEMA] Processamento Multi-Timeframe finalizado com sucesso.")
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

        layout_principal.addWidget(self.criar_modulo_1(), 1) 
        layout_principal.addWidget(self.criar_modulo_2(), 2) 
        layout_principal.addWidget(self.criar_modulo_3(), 2) 

    # --------------------------------------------------------
    # MÓDULO 1: Configuração Geral e Timeframes
    # --------------------------------------------------------
    def criar_modulo_1(self):
        grupo = QGroupBox("") # Título removido
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)
        form = QFormLayout()
        form.setSpacing(12)

        self.input_ea = QLineEdit("Bollinger")
        self.input_ativo = QLineEdit("EURUSD_custom")
        
        # Grid de Timeframes
        self.widget_tfs = QWidget()
        self.grid_tfs = QGridLayout(self.widget_tfs)
        self.grid_tfs.setSpacing(10)
        self.check_tfs = {}
        
        tfs_lista = [("5M", 5), ("15M", 15), ("30M", 30), ("60M", 60), ("120M", 120)]
        for i, (nome, valor) in enumerate(tfs_lista):
            chk = QCheckBox(nome)
            chk.setProperty("minutos", valor)
            if nome == "30M": chk.setChecked(True)
            self.check_tfs[nome] = chk
            self.grid_tfs.addWidget(chk, i // 2, i % 2)

        self.spin_ano = QSpinBox()
        self.spin_ano.setRange(2000, 2050)
        self.spin_ano.setValue(2025)

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
        form.addRow("Timeframes:", self.widget_tfs)
        form.addRow(QLabel(" ")) 
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
        grupo = QGroupBox("") # Título removido
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)

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

        botoes_tabela = QHBoxLayout()
        btn_add = QPushButton("+ Adicionar Parâmetro")
        btn_add.clicked.connect(self.adicionar_linha_tabela)
        btn_del = QPushButton("- Remover Parâmetro")
        btn_del.clicked.connect(self.remover_linha_tabela)
        botoes_tabela.addWidget(btn_add)
        botoes_tabela.addWidget(btn_del)

        layout.addWidget(self.tabela)
        layout.addLayout(botoes_tabela)

        layout.addWidget(QLabel("\nCenários de Configuração Ativos:"))
        self.grupo_cenarios = QWidget()
        grade_cenarios = QGridLayout(self.grupo_cenarios)
        grade_cenarios.setSpacing(15)
        
        cenarios_nomes = ["TTT", "TTF", "TFT", "TFF", "FTT", "FTF", "FFT", "FFF"]
        self.check_cenarios = {}
        
        for i, cenario in enumerate(cenarios_nomes):
            chk = QCheckBox(cenario)
            chk.setChecked(True if cenario == "TTT" else False)
            self.check_cenarios[cenario] = chk
            grade_cenarios.addWidget(chk, i // 4, i % 4)

        layout.addWidget(self.grupo_cenarios)
        return grupo

    # --------------------------------------------------------
    # MÓDULO 3: Telemetria e Execução
    # --------------------------------------------------------
    def criar_modulo_3(self):
        grupo = QGroupBox("") # Título removido
        layout = QVBoxLayout(grupo)
        layout.setSpacing(15)

        self.console = QTextEdit()
        self.console.setReadOnly(True)
        self.console.setObjectName("consoleMatrix")
        self.console.setFont(QFont("Consolas", 12))
        self.console.append("SISTEMA PRONTO.\nAGUARDANDO COMANDO PARA DECOLAGEM...")

        self.barra_progresso = QProgressBar()
        self.barra_progresso.setValue(0)
        self.barra_progresso.setFormat("Aguardando... %p%")

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

    def adicionar_linha_tabela(self):
        row = self.tabela.rowCount()
        self.tabela.insertRow(row)
        for c in range(4): self.tabela.setItem(row, c, QTableWidgetItem(""))

    def remover_linha_tabela(self):
        row = self.tabela.currentRow()
        if row >= 0: self.tabela.removeRow(row)

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
            except: return None

        tfs_selecionados = []
        for nome, chk in self.check_tfs.items():
            if chk.isChecked():
                tfs_selecionados.append({"nome": nome, "valor": chk.property("minutos")})

        configs_ativas = [n for n, chk in self.check_cenarios.items() if chk.isChecked()]

        return {
            "ea_name": self.input_ea.text().strip(),
            "symbol": self.input_ativo.text().strip(),
            "timeframes_selecionados": tfs_selecionados,
            "train_until_year": self.spin_ano.value() -1,
            "train_years": self.spin_treino.value(),
            "forward_years": self.spin_forward.value(),
            "n_janelas": self.spin_janelas.value(),
            "parametros_otimizados": parametros,
            "configuracoes_ativas": configs_ativas
        }

    def iniciar_operacao(self):
        dados = self.capturar_dados()
        if not dados or not dados['timeframes_selecionados'] or not dados['configuracoes_ativas']:
            QMessageBox.critical(self, "Erro", "Selecione pelo menos um Timeframe e um Cenário!")
            return

        self.btn_iniciar.setEnabled(False)
        self.btn_parar.setEnabled(True)
        self.console.clear()
        
        self.worker = TrabalhadorWFO(dados)
        self.worker.sinal_log.connect(self.console.append)
        self.worker.sinal_progresso.connect(self.atualizar_progresso)
        self.worker.sinal_fim.connect(self.finalizar_operacao)
        self.worker.start()

    def parar_operacao(self):
        if hasattr(self, 'worker'): self.worker.parar()
        self.btn_parar.setEnabled(False)

    def atualizar_progresso(self, atual, total):
        self.barra_progresso.setMaximum(total)
        self.barra_progresso.setValue(atual)

    def finalizar_operacao(self):
        self.btn_iniciar.setEnabled(True)
        self.btn_parar.setEnabled(False)
        self.barra_progresso.setFormat("Concluído 100%" if self.barra_progresso.value() == self.barra_progresso.maximum() else "Interrompido")

    def aplicar_estilo_qss(self):
        estilo = """
        /* ==================== GLOBAL ==================== */
        * { font-family: 'Segoe UI', sans-serif; font-size: 14px; }
        QMainWindow { background-color: #121216; }
        QLabel { color: #A0AABF; font-weight: 600; }

        /* ==================== CAIXAS DE GRUPO ==================== */
        QGroupBox {
            color: #61AFEF;
            border: 1px solid #282C34;
            border-radius: 8px;
            margin-top: 15px;
            padding: 20px 15px 15px 15px;
            background-color: #181A1F;
        }

        /* ==================== INPUTS ==================== */
        QLineEdit, QSpinBox, QComboBox { 
            background-color: #21252B; color: #D7DAE0; border: 1px solid #333842; 
            padding: 8px 12px; border-radius: 6px; font-size: 15px;
        }
        QLineEdit:focus, QSpinBox:focus, QComboBox:focus { border: 1px solid #61AFEF; }

        /* ==================== TABELA ==================== */
        QTableWidget { 
            background-color: #1E2227; alternate-background-color: #21252B; 
            color: #D7DAE0; gridline-color: #282C34; border: 1px solid #333842; border-radius: 6px;
        }
        QHeaderView::section { 
            background-color: #181A1F; color: #ABB2BF; padding: 8px; border: none; 
            border-right: 1px solid #282C34; border-bottom: 2px solid #61AFEF; font-weight: bold;
        }

        /* ==================== CHECKBOX ==================== */
        QCheckBox { color: #ABB2BF; font-size: 15px; font-weight: 600; }
        QCheckBox::indicator { width: 22px; height: 22px; }
        QCheckBox::indicator:unchecked { border: 2px solid #4C566A; background: #21252B; border-radius: 5px; }
        QCheckBox::indicator:checked { border: 2px solid #98C379; background: #98C379; border-radius: 5px; }

        /* ==================== CONSOLE ==================== */
        #consoleMatrix { 
            background-color: #0E1013; color: #98C379; border: 2px inset #1E2227; 
            border-radius: 6px; padding: 15px; 
        }

        /* ==================== PROGRESS BAR ==================== */
        QProgressBar { 
            border: 1px solid #333842; border-radius: 8px; text-align: center; color: white; 
            font-weight: bold; background-color: #181A1F; min-height: 25px;
        }
        QProgressBar::chunk { 
            background-color: qlineargradient(x1: 0, y1: 0, x2: 1, y2: 0, stop: 0 #61AFEF, stop: 1 #C678DD);
            border-radius: 7px;
        }

        /* ==================== BOTÕES ==================== */
        QPushButton { 
            background-color: #282C34; color: #ABB2BF; border-radius: 6px; padding: 10px; font-weight: bold; 
        }
        QPushButton:hover { background-color: #3E4452; color: #FFF; }
        #btnIniciar { background-color: #98C379; color: #121216; font-size: 18px; padding: 18px; border: none; }
        #btnIniciar:hover { background-color: #7CB35F; }
        #btnParar { background-color: #E06C75; color: #121216; font-size: 18px; padding: 18px; border: none; }
        #btnParar:hover { background-color: #C85961; }
        """
        self.setStyleSheet(estilo)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())
