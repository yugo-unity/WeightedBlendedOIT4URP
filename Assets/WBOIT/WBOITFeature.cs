using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace WBOIT
{
    /// <summary>
    /// 半透明バッファの解像度（カメラカラーに対する縮小率）
    /// </summary>
    public enum BufferScale
    {
        Full = 1,
        Half = 2,
        Quarter = 4,
    }

    [System.Serializable]
    public class FeatureSettings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
        public RenderQueueType renderQueueType = RenderQueueType.Transparent;
        public LayerMask layerMask = 0;

        [Tooltip("半透明バッファの解像度。Full以外はカメラデプスを縮小して蓄積し、デプスを考慮してアップサンプルする")]
        public BufferScale bufferScale = BufferScale.Full;
        [Tooltip("アップサンプル時、周囲のデプス差がこの割合（フル解像度のデプスに対する相対値）を超えたらバイリニアをやめて最もデプスが近いテクセルを使う")]
        [Range(0.001f, 1f)]
        public float upsampleDepthThreshold = 0.1f;

        [Tooltip("半透明の蓄積パスのシェーディングレート（VRS）。描画先の解像度は変わらずピクセルシェーダーの実行回数だけ減る。非対応の環境では1x1になる")]
        public ShadingRateFragmentSize accumulateShadingRate = ShadingRateFragmentSize.FragmentSize1x1;
    }

    public class WBOITFeature : ScriptableRendererFeature
    {
        public FeatureSettings settings = new FeatureSettings();
        // NOTE: Shader.Findはどこからも参照されていないシェーダーをPlayerで見つけられないので、アセットから参照してビルドに含める
        [SerializeField] Shader blitShader;
        WBOITPass wboitPass;

        const string k_BlitShaderName = "WBOIT/Blit";


        public override void Create()
        {
#if UNITY_EDITOR
            if (this.blitShader == null)
            {
                this.blitShader = Shader.Find(k_BlitShaderName);
                if (this.blitShader != null)
                    UnityEditor.EditorUtility.SetDirty(this);
            }
#endif
            // NOTE: OnValidateからも呼ばれるので作り直す前に解放する
            this.wboitPass?.Dispose();
            this.wboitPass = new WBOITPass(settings, this.blitShader);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            // NOTE: supported only Game or Scene View
            if ((renderingData.cameraData.cameraType & (CameraType.Game | CameraType.SceneView)) == 0)
                return;

            this.wboitPass.Setup(renderingData.cameraData.cameraTargetDescriptor);
            renderer.EnqueuePass(this.wboitPass);
        }

        protected override void Dispose(bool disposing)
        {
            this.wboitPass.Dispose();
        }
    }
}
