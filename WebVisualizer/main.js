import './style.css';
import mockData from './mockDiffs.json';

function init() {
  const app = document.getElementById('app');
  
  app.innerHTML = `
    <header>
      <div class="header-top">
        <div class="title-container">
          <h1>DProvenance Explorer</h1>
          <p>Reasoning structural diff visualizer</p>
        </div>
        <div class="stats-bar">
          <div class="stat-item">
            <span class="stat-label">Runs</span>
            <span class="stat-value">${mockData.summary.runs}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Risk</span>
            <span class="stat-value risk-${mockData.summary.regressionRisk.toLowerCase()}">${mockData.summary.regressionRisk}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Changed Paths</span>
            <span class="stat-value">${mockData.summary.changedLogicPaths}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Fingerprint</span>
            <span class="stat-value">${mockData.summary.structuralFingerprint}</span>
          </div>
        </div>
      </div>
    </header>
    
    <div class="timeline-section">
      <svg class="timeline-svg" viewBox="0 0 600 120">
        <!-- Run A line -->
        <path class="timeline-line" d="M 50,30 L 250,30" />
        
        <!-- Drift line -->
        <path class="timeline-line drift" d="M 250,30 C 350,30 350,90 450,90" />
        <text class="drift-label" x="350" y="55">regression</text>
        
        <!-- Run B line -->
        <path class="timeline-line" d="M 50,90 L 450,90" />
        
        <!-- Nodes -->
        <circle class="timeline-node" cx="250" cy="30" r="6" />
        <text class="timeline-text" x="250" y="15">${mockData.timeline.runA.label}</text>
        <text class="timeline-label" x="250" y="50">${mockData.timeline.runA.date}</text>
        
        <circle class="timeline-node" cx="450" cy="90" r="6" />
        <text class="timeline-text" x="450" y="110">${mockData.timeline.runB.label}</text>
        <text class="timeline-label" x="450" y="75">${mockData.timeline.runB.date}</text>
      </svg>
    </div>
    
    <div class="main-content">
      <div class="drift-card">
        <div class="drift-score-container">
          <span class="drift-score">${mockData.metrics.driftScore}%</span>
          <span class="drift-title">Reasoning Drift</span>
        </div>
        <div class="drift-stats">
          <div class="drift-stat-row added">
            <span>Added Nodes</span>
            <span>+${mockData.metrics.addedNodes}</span>
          </div>
          <div class="drift-stat-row removed">
            <span>Removed Nodes</span>
            <span>-${mockData.metrics.removedNodes}</span>
          </div>
          <div class="drift-stat-row changed">
            <span>Changed Paths</span>
            <span>~${mockData.metrics.changedPaths}</span>
          </div>
        </div>
      </div>
      
      <div class="tree-container">
        ${renderTree(mockData.tree)}
      </div>
    </div>
  `;
}

function renderTree(node) {
  let html = `<div class="tree-node-group">`;
  
  html += `
    <div class="tree-node">
      <div class="tree-content">
        <span class="node-label">${node.label}</span>
        ${node.type !== 'unchanged' ? `<span class="node-badge ${node.type}">${node.type === 'added' ? '+ added' : node.type === 'removed' ? '- removed' : '~ changed'}</span>` : ''}
      </div>
    </div>
  `;
  
  if (node.details) {
    html += `
      <div class="node-details">
        <div class="details-row">
          <span class="details-key">Run A:</span>
          <span class="details-value">${node.details.runA}</span>
        </div>
        <div class="details-row">
          <span class="details-key">Run B:</span>
          <span class="details-value">${node.details.runB}</span>
        </div>
      </div>
    `;
  }
  
  if (node.children && node.children.length > 0) {
    node.children.forEach(child => {
      html += renderTree(child);
    });
  }
  
  html += `</div>`;
  return html;
}

document.addEventListener('DOMContentLoaded', init);
